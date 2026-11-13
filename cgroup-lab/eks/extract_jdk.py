#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Extract a JDK .tar.gz into a directory, without its top-level directory.

Used by the init container of the cgroup lab, because the Amazon Linux 2023 container image
has Python but no tar. Standard library only (Python 3.9). Every member is checked before
anything is written: absolute paths, ".." components, device files and links that point
outside the destination are rejected.

Usage: extract_jdk.py TARBALL DEST
"""
import os
import posixpath
import shutil
import sys
import tarfile


def member_path(name):
    """Path of a member below the top-level directory, or None for the top directory."""
    if name.startswith("/") or "\\" in name:
        raise ValueError("absolute or unusual member path: %r" % name)
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if ".." in parts:
        raise ValueError("member path with '..': %r" % name)
    if len(parts) <= 1:
        return None
    return "/".join(parts[1:])


def inside(rel_dir, target):
    """True when the link target, relative to rel_dir, stays inside the destination."""
    if target.startswith("/"):
        return False
    joined = posixpath.normpath(posixpath.join(rel_dir, target))
    return joined != ".." and not joined.startswith("../")


def plan(tar):
    """Validate every member and return (member, relative path) pairs."""
    out = []
    for m in tar.getmembers():
        rel = member_path(m.name)
        if rel is None:
            if not m.isdir():
                raise ValueError("unexpected top-level member: %r" % m.name)
            continue
        if m.isdir() or m.isfile():
            pass
        elif m.issym():
            if not inside(posixpath.dirname(rel), m.linkname):
                raise ValueError("symlink leaves the destination: %r -> %r" % (m.name, m.linkname))
        elif m.islnk():
            if member_path(m.linkname) is None:
                raise ValueError("hard link to the top directory: %r" % m.name)
        else:
            raise ValueError("unsupported member type: %r" % m.name)
        out.append((m, rel))
    return out


def extract(tarball, dest):
    if os.path.exists(dest):
        raise ValueError("destination exists: %s" % dest)
    with tarfile.open(tarball, "r:gz") as tar:
        members = plan(tar)
        os.makedirs(dest)
        links = []
        for m, rel in members:
            path = os.path.join(dest, *rel.split("/"))
            if m.isdir():
                os.makedirs(path, exist_ok=True)
            elif m.isfile():
                os.makedirs(os.path.dirname(path), exist_ok=True)
                src = tar.extractfile(m)
                with open(path, "wb") as fh:
                    shutil.copyfileobj(src, fh)
                # Owner and group only: the init and main containers run as the same user.
                os.chmod(path, 0o750 if m.mode & 0o111 else 0o640)
            else:
                links.append((m, path))
        # Links last, so that hard link targets exist.
        for m, path in links:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if m.issym():
                os.symlink(m.linkname, path)
            else:
                target = os.path.join(dest, *member_path(m.linkname).split("/"))
                shutil.copyfile(target, path)
                shutil.copymode(target, path)
    return len(members)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: extract_jdk.py TARBALL DEST\n")
        return 2
    try:
        count = extract(argv[1], argv[2])
    except (ValueError, OSError, tarfile.TarError) as e:
        sys.stderr.write("extract_jdk.py: %s\n" % e)
        return 1
    print("extracted %d members into %s" % (count, argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
