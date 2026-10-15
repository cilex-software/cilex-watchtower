# Recorded component license coverage, version 1

`--license-manifest /absolute/path/to/review.json` supplies the review for an
exact application source, deployment-helper tree and dependency input set.
These identities remain separate in `context`. The build compares them with
its own records and rejects a stale review, mismatched notice hash or unsafe
path in development and production modes alike. This check performs no network
requests and does not decide what any license permits.

An initial development build produces `licenses/COMPONENT-LICENSES.json` with
the exact context and unassigned payload paths, plus `LICENSE-COVERAGE.json`.
Copy the draft outside the package, review its components and supply the result
to a later build with unchanged inputs. Keep the original immutable artifact;
never edit a signed package in place. Put notice, review-basis and source-offer
files in the explicitly selected `licenses_dir` input. The two generated JSON
filenames are reserved and must not be in that input directory.

The machine-readable format is
[`manifests/license-coverage.schema.json`](manifests/license-coverage.schema.json).
Each component records its exact version, license expression, original source,
notice hashes, redistribution basis and source-obligation evidence. A component
entry has this shape (digests and example values must be replaced):

```json
{
  "id": "example-component",
  "version": "1.2.3",
  "license_expression": "LicenseRef-Reviewed-Example",
  "paths": ["watchtower.app/Contents/Frameworks/libexample.dylib"],
  "notices": [{"path": "licenses/example/NOTICE.txt", "sha256": "<64 lowercase hex characters>"}],
  "source": {"kind": "archive", "url": "https://example.org/example-1.2.3.tar.gz", "sha256": "<64 lowercase hex characters>"},
  "redistribution": {
    "basis": "The reviewer records the applicable distribution basis in REVIEW.txt.",
    "source_obligation": "source-offer",
    "evidence": [{"path": "licenses/example/REVIEW.txt", "sha256": "<64 lowercase hex characters>"}]
  }
}
```

Every regular payload file needs at least one component mapping. Paths are
exact relative POSIX paths, including Unicode and spaces; globs are not
expanded. Several components may share one file: explicitly map components
embedded in Python archives, static executables and other combined content.
The tool cannot infer these embedded components; the named reviewer attests
that they have been included. Repeated paths within one component are rejected.
Contained framework symlinks refer to their already covered regular targets.
The final artifact inventory separately hashes notices, review records and
generated code-signature metadata; these do not need their own component rows.

Source evidence supports an HTTPS archive URL with SHA-256, an HTTPS Git URL
with an exact commit, or a hashed source archive inside `licenses/`. URLs may
not contain credentials, query parameters or fragments. Remote source records
are immutable references, not proof that the source remains available offline
or that an offer meets a license's requirements. `source-included` requires
bundled source evidence. Other source-obligation decisions require a hashed
review/offer document even when the reviewer records no obligation.

To mark a review complete, remove all unassigned paths, set `review.status` to
`complete`, name `review.reviewer`, supply UTC `review.reviewed_at`, retain
`review.scope: all-distributed-content`, and set `review.attestation` to
`all-distributed-components-including-embedded-code`. A complete status with
missing file mappings is rejected. Production additionally requires
`--accept-licenses yes`; an arbitrary `license_review: complete` option is ignored.
Development output may remain `unverified` with an explicit exhaustive gap
report. Production signing stays blocked until recorded coverage is complete.

The resulting `license_review: complete` means the supplied structural review
passed validation. It is **not legal approval**, and reports explicitly retain
`legal_approval: not-inferred`. A filename containing “Qt” or “FFmpeg” proves
neither license completeness nor permission to redistribute.
