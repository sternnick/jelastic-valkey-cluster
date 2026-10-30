#!/usr/bin/env python3
"""sbom.py - a CycloneDX 1.5 SBOM for what this repository pins, generated on demand.

    python3 sbom.py            # write sbom.json (gitignored: it is generated, never committed)
    python3 sbom.py --check    # generate, scan for exposure, report, write nothing

Two questions this answers, both of them checkable offline:

* which image tags and which ref does THIS version name - the tags offered in `manifest.jps`, the
  default, the probe's tag, the ports, and the commit these files came from;
* does the document it produces carry any of the identifiers this repository keeps out of itself -
  the same rules `tests/validate.sh` applies to files, applied to every string in the SBOM.

What it does not claim: it is not a container package inventory. The image's own OS package set
belongs to the image, and a faithful list comes from scanning it
(`trivy image valkey/valkey:9.1.3-alpine3.24`). Nor does it resolve tags to digests: a resolved digest
describes an upstream manifest list at the moment of the call, so an SBOM that carried one would be a
snapshot of Docker Hub rather than a statement about this repository, and would need its own pinning
and expiry policy to be worth trusting. The tag this file names is pinned to an Alpine release for
exactly that reason - see the note in `manifest.jps`.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(REPO_ROOT, "manifest.jps")
PROBE = os.path.join(REPO_ROOT, "probes", "network-probe.jps")

# The rules tests/validate.sh applies to tracked files, applied here to every string this writes. A
# generated file that carries a node id is still a file that carries a node id.
#
# Three separate rules, because "no account names" is not what is meant here:
#   (a) hard prohibitions - anything that identifies an account or a machine: an email address, a
#       platform node or environment id, a home path, a GitHub Pages or codespace URL (both carry a
#       login), an ssh remote, the noreply domain;
#   (b) THIS project's own coordinates are a placeholder - any URL naming this repository must say
#       <owner>, because that line is the one every installer edits anyway;
#   (c) upstream dependencies are named on purpose. valkey-io/valkey is a fact about a dependency, not
#       about whoever runs this repository, so it is allowed by list, and a new upstream is a
#       deliberate one-line edit that a reviewer sees.
#
# Each pattern is written so it cannot match its own line here: the hostnames use a class for the dot,
# and the digit runs are {5,} against the four-digit example in the docstring.
IDENTIFIERS = [
    (re.compile(r"\b[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}"), "an email address"),
    (re.compile(r"\bnode[0-9]{5,}\b"), "a platform node id"),
    (re.compile(r"\benv-[0-9]{5,}\b"), "a platform environment id"),
    (re.compile(r"/(?:var[/]home|Users|home)/[A-Za-z0-9._-]+/"), "a local home path"),
    (re.compile(r"\busers[.]noreply[.]github[.]com\b"), "a GitHub noreply domain"),
    (re.compile(r"\bgit@[A-Za-z0-9.-]+"), "an ssh git remote"),
    (re.compile(r"\b[A-Za-z0-9][A-Za-z0-9.-]*[.]github[.]io\b"), "a GitHub Pages URL, which carries a login"),
    (re.compile(r"\b[A-Za-z0-9-]+[.]githubpreview[.]dev\b"), "a codespace preview URL"),
]

# (b) A URL that points at THIS repository: its owner segment must be the placeholder, because the
#     account that hosts it is the reader's business, not the documentation's.
OWN_URL = re.compile(r"(?:raw[.]githubusercontent[.]com|github[.]com)/([A-Za-z0-9_.<>-]+)/"
                     r"jelastic-valkey-cluster")

# (c) The owner of any github URL, checked against a short declared list. An upstream dependency
#     belongs here by name; an account does not belong here at all.
GITHUB_OWNER = re.compile(r"(?:raw[.]githubusercontent[.]com|github[.]com)/([A-Za-z0-9_.<>-]+)")
UPSTREAM_OK = {"valkey-io", "jelastic-jps", "earendil-works"}
PLACEHOLDER_OWNERS = {"<owner>", "<your-account>", "<account>", "<org>"}

TAG_BASE = re.compile(r"^(?P<valkey>[0-9][0-9.]*?)(?:-alpine(?P<alpine>[0-9.]+))?$")

# One offered tag is an alias rather than a version: 9.2-alpine3.24 is built from the 9.2.0-rc1
# source, which is what the image's own config says (ENV VALKEY_VERSION=9.2.0-rc1). The others name
# their source version directly, and all five exist upstream (checked against the repository's tag
# list, not assumed).
SOURCE_ALIAS = {"9.2": "9.2.0-rc1"}


def source_version(valkey):
    return SOURCE_ALIAS.get(valkey, valkey)


def field(text, name):
    """A scalar field, indented or not. Globals live two spaces in, and a regex that forgets that
    returns None for every port - which is how an SBOM full of nulls gets published."""
    m = re.search(r"^[ \t]*%s:[ \t]*(\S.*)$" % re.escape(name), text, re.M)
    return m.group(1).strip().strip("'\"") if m else None


def field_block(text, name):
    """The body of the settings field whose `name:` is `name`.

    Two things a naive version gets wrong, both of which make an SBOM lie quietly: the fields are
    YAML sequence items, so the line is `- name: x` and a pattern anchored on `name:` matches
    nothing; and the body must stop at the NEXT field, or the first `values:` found is somebody
    else's."""
    m = re.search(
        r"^[ \t]*(?:-[ \t]*)?name:[ \t]*%s[ \t]*\n"
        r"((?:(?![ \t]*(?:-[ \t]*)?name:)[ \t]+.*\n?)*)" % re.escape(name), text, re.M)
    return m.group(1) if m else ""


def field_default(text, name):
    d = re.search(r"^[ \t]+default:[ \t]*(\S.*)$", field_block(text, name), re.M)
    return d.group(1).strip().strip("'\"") if d else None


def list_keys(block):
    """The keys of a `values:` block, in order, as YAML will hand them to the platform.

    Bounded by indentation, not by a regex over the rest of the field: `default:` and `required:` sit
    at the same column as the mapping keys, and a pattern that runs past the end of the block hands
    back those words as if they were image tags."""
    keys = []
    values_indent = None
    for line in block.splitlines():
        if values_indent is None:
            m = re.match(r"^([ \t]*)values:[ \t]*$", line)
            if m:
                values_indent = len(m.group(1))
            continue
        if not line.strip():
            continue
        if len(re.match(r"^[ \t]*", line).group(0)) <= values_indent:
            break
        k = re.match(r"^[ \t]+([\"']?)([^:\"'#]+?)\1[ \t]*:", line)
        if k:
            keys.append(k.group(2).strip())
    return keys


def tag_values(text):
    return list_keys(field_block(text, "valkeyTag"))


def git(*args):
    try:
        out = subprocess.run(["git", "-C", REPO_ROOT, *args], capture_output=True, text=True,
                             timeout=15)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def source_ref():
    """Where these files came from. The resolution method is stated, because a commit sha alone does
    not tell a reader whether it was resolved by tag, by HEAD, or by guesswork."""
    head = git("rev-parse", "HEAD")
    exact = git("describe", "--tags", "--exact-match")
    if not head:
        return {"name": "jelastic-valkey-cluster",
                "note": "not a git checkout, so there is no source revision to record"}
    entry = {"repository": "https://github.com/<owner>/<repo>",
             "revision": head,
             "resolved_via": "git rev-parse HEAD"}
    if exact:
        entry["version"] = exact.lstrip("v")
        entry["resolved_via"] = "git describe --tags --exact-match"
    else:
        # The working tree carries this version, and it is the truth about what these files are.
        entry["version"] = field(open(MANIFEST, encoding="utf-8").read(), "version")
        entry["nearest_tag"] = git("describe", "--tags", "--abbrev=0") or None
        entry["note"] = ("HEAD is not the commit any tag names, so this describes an unreleased "
                         "tree: pin before you rely on the revision")
    return entry


def build():
    text = open(MANIFEST, encoding="utf-8").read()
    probe_text = open(PROBE, encoding="utf-8").read()
    version = field(text, "version")
    base = field(text, "baseUrl") or ""

    components = [{
        "bom-ref": "pkg:generic/jelastic-valkey-cluster@%s" % version,
        "type": "application",
        "name": "jelastic-valkey-cluster",
        "version": version,
        "description": "JPS application manifest: a Valkey cluster formed at install time on "
                       "Jelastic Cloud",
        "licenses": [{"license": {"id": "BSD-3-Clause",
                                  "url": "https://github.com/<owner>/<repo>/blob/<ref>/LICENSE"}}],
        "properties": [{"name": "valkey:pinned-ref", "value": base.rsplit("/", 1)[-1]},
                       {"name": "valkey:manifest", "value": "manifest.jps"}],
    }]

    for tag in tag_values(text):
        parsed = TAG_BASE.match(tag)
        if not parsed:
            # A non-version-shaped option (an offered `latest`, a suffix this regex does not know)
            # is a bug in this tool or in the tag list. Say so; do not drop a component quietly.
            raise SystemExit("FAIL  sbom.py does not understand the offered tag %r - update "
                             "TAG_BASE rather than let an image disappear from the SBOM" % tag)
        valkey, alpine = parsed.group("valkey"), parsed.group("alpine")
        src = source_version(valkey)
        purl = "pkg:docker/valkey/valkey@%s" % tag
        components.append({
            "bom-ref": purl,
            "type": "container",
            "name": "valkey/valkey",
            "version": tag,
            "purl": purl,
            "description": "Official Valkey image, source %s, %s base"
                           % (src, "Alpine %s" % alpine if alpine else "unspecified distribution"),
            "licenses": [{"license": {"id": "BSD-3-Clause",
                                      "url": "https://github.com/valkey-io/valkey/blob/%s/COPYING"
                                             % src}}],
            "properties": [
                {"name": "valkey:source-version", "value": src},
                {"name": "valkey:source-ref",
                 "value": "https://github.com/valkey-io/valkey/tree/%s" % src},
                {"name": "alpine:base-release", "value": alpine or "unpinned - see manifest.jps"},
                {"name": "platform:supported-base-os", "value": "Alpine 3"},
                {"name": "digest:resolved", "value": "no - this tool does not resolve digests"},
            ],
        })

    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": "urn:uuid:%s" % uuid.uuid4(),
        "version": 1,
        "metadata": {
            "timestamp": datetime.datetime.now(datetime.timezone.utc)
                         .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tools": [{"vendor": "jelastic-valkey-cluster contributors", "name": "sbom.py",
                       "version": version}],
            "component": {"type": "platform", "name": "Jelastic Cloud",
                          "version": field(text, "targetEditions") or "any",
                          "description": "Virtuozzo Application Platform; custom Docker images, "
                                         "amd64, base OS on the platform's supported list"},
            "properties": [
                {"name": "valkey:client-port", "value": field(text, "clientPort")},
                {"name": "valkey:cluster-bus-port", "value": field(text, "clusterBusPort")},
                {"name": "valkey:default-tag", "value": field_default(text, "valkeyTag")},
                {"name": "valkey:node-count-default", "value": field_default(text, "nodeCount")},
                {"name": "valkey:replicas-default",
                 "value": field_default(text, "replicasPerPrimary")},
                # A tag is a mutable name, so the SBOM says plainly whether it alone is enough.
                {"name": "supply-chain:immutability",
                 "value": "tags only - pin the digest of what you deploy (docker image inspect "
                          "--format '{{index .RepoDigests 0}}' valkey/valkey:<tag>)"},
            ],
            "primaryComponent": {"type": "application", "name": "jelastic-valkey-cluster",
                                 "version": version},
            "sources": [source_ref()],
        },
        "components": components,
    }


def find_identifiers(s):
    """Every way this string can name an account, a deployment, or a machine. One implementation, on
    purpose: tests/validate.sh imports it and applies it to files, so the scan of a generated SBOM
    and the scan of a committed file cannot disagree about what an identifier is."""
    hits = []
    for rx, why in IDENTIFIERS:
        for hit in rx.finditer(s):
            hits.append("%s: %s" % (why, hit.group(0)[:60]))
    named = OWN_URL.search(s)
    if named and named.group(1) not in PLACEHOLDER_OWNERS:
        hits.append("this repository's own coordinates name an account (%s) - use <owner>: %s"
                    % (named.group(1), s[:70]))
    for hit in GITHUB_OWNER.finditer(s):
        owner = hit.group(1)
        if owner in UPSTREAM_OK or owner in PLACEHOLDER_OWNERS:
            continue
        hits.append("a github URL owned by %r, which is neither a declared upstream nor a "
                    "placeholder: %s" % (owner, s[:70]))
    return hits


def scan(obj):
    """Every string value in the document, against the rules above. Keys are not scanned: they are
    this file's own vocabulary, and the `github` in `resolved_via` is a field name, not a URL."""
    hits = []

    def walk(v):
        if isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, str):
            hits.extend(find_identifiers(v))

    walk(obj)
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO_ROOT, "sbom.json"))
    ap.add_argument("--check", action="store_true",
                    help="generate, scan for exposure, report, and write nothing")
    args = ap.parse_args()

    doc = build()
    hits = scan(doc)

    if args.check:
        fd, tmp = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(doc, fh, indent=2)
            size, parsed = os.path.getsize(tmp), json.load(open(tmp, encoding="utf-8"))
        finally:
            os.unlink(tmp)
        print("ok    sbom.py generates a %d B CycloneDX 1.5 document that parses, %d component(s)"
              % (size, len(parsed["components"])))
        for h in hits:
            print("FAIL  the SBOM carries %s" % h)
        return 1 if hits else 0

    if hits:
        for h in hits:
            print("FAIL  refusing to write an SBOM that carries %s" % h, file=sys.stderr)
        return 1
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    print("wrote %s (%d components; scan clean)"
          % (os.path.relpath(os.path.abspath(args.out), os.getcwd()), len(doc["components"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
