# gdrive-s3-gateway

## Idea

An S3-compatible API in front of Google Drive, so existing S3 clients (Velero,
Longhorn's backup target, `aws s3 cp`, etc.) can use an existing Google Drive
storage subscription as a backup destination — without provisioning a
dedicated VM or paying for object storage (R2/S3) on top of storage already
being paid for.

Built on `rclone` (Drive backend + `rclone serve s3`), packaged as a small,
single-purpose service rather than written from scratch.


## Scope

**In scope**

- A container running `rclone serve s3` against a `drive:` remote, exposing
  an S3-compatible endpoint on the internal network.
- Static access-key/secret-key auth for the gateway (consumed by Velero /
  Longhorn, not exposed publicly).
- One Google Drive folder acting as the sole "bucket" — no multi-bucket
  support needed.
- Enough reliability to serve as a *scheduled batch* backup target: nightly
  Velero backup, nightly Longhorn snapshot upload. Not a live/hot path.
- Basic observability: gateway logs, a way to tell "last backup succeeded"
  from "gateway down" vs "Drive API rejected the call".

**Out of scope (for v1)**

- High availability / multiple replicas — a single pod is fine; backups
  are not latency-sensitive.
- General-purpose app storage — this is a backup target only, not a
  replacement for Longhorn/local-path as a PVC provisioner.
- Multi-user / multi-tenant auth — one static key pair is enough.
- Full S3 API coverage — only the subset Velero and Longhorn actually use
  (PUT/GET/DELETE/LIST objects, multipart upload) needs to work.

## Targets / milestones

1. **Drive remote works standalone** — `rclone config` produces a working
   `drive:` remote locally; can `rclone copy`/`ls` a test file by hand.
2. **Gateway runs as a container** — `rclone serve s3` starts against that
   remote with `--auth-key`, reachable over HTTP(S) locally (e.g. via
   `docker run` before touching k8s).
3. **S3 client round-trip** — using `aws-cli` or `s3cmd` pointed at the
   gateway: put an object, list it, get it back byte-identical, delete it.
4. **Runs in-cluster** — packaged as a Deployment + Service (ClusterIP),
   `rclone.conf` and the auth key pulled from Secrets (never committed in
   plaintext — SealedSecret if it lands in a GitOps repo).
5. **Velero round-trip** — configure a `BackupStorageLocation` against the
   gateway, run a real backup of a low-stakes namespace, then restore it
   into a scratch namespace and diff.
6. **Longhorn round-trip** — configure Longhorn's backup target against the
   gateway, back up one volume, restore it, verify data matches.
7. **Failure behavior is legible** — kill the gateway pod mid-backup and
   confirm Velero/Longhorn report a clear failure (not a silent partial
   backup); confirm what happens on Drive API rate-limit (HTTP 403/429).

## Open questions / risks to resolve during the build

- Whether `rclone serve s3`'s multipart upload support is solid enough for
  Velero's larger backup tarballs, or whether large backups need chunking
  tuned via rclone flags.
- Google Drive API quota behavior under a burst of small-object PUTs (Velero
  backups can be thousands of small objects) — may need `--auth-key` +
  concurrency limits to stay under per-100s quota.
- What "the gateway is down" alerting looks like, so a failed backup doesn't
  go unnoticed for weeks.
- Whether Drive's ToS is comfortable with this usage pattern at the volume
  this will actually see (personal backup traffic, not bulk redistribution).
- Confirmed while building this: testing the gateway with **rclone itself as
  the S3 client** (`rclone copyto` against an `:s3` remote pointed at the
  gateway) produces false-negative "object not found" / verification errors
  even though the object is written correctly — rclone-to-`rclone serve s3`
  round-trips don't agree on post-write verification. A real S3 SDK client
  (boto3, aws-cli, s3cmd) round-trips cleanly. Velero and Longhorn both use
  real S3 SDKs, so this shouldn't affect them, but don't use `rclone` itself
  to smoke-test the gateway — use an actual S3 client.
- **Confirmed and quantified against real Drive** (using `s3tester` +
  a scripted retry-until-visible check, not just a single object): a burst of
  20 concurrent `PUT`s left **all 20** objects returning `NoSuchKey` on
  immediate `GET`; still 16/20 missing at +5s; all 20 became readable by
  +15s total. A follow-up `DELETE` pass on all 20 succeeded — the data was
  never lost, Drive's `files.list` (which `rclone serve s3` uses to resolve
  object lookups) just lags behind bursty concurrent inserts by up to ~15s.
  A single sequential PUT+GET only showed ~2s of lag, so **concurrency makes
  it worse**, not object count alone.
  Implication for this project: fine for a nightly batch job that doesn't
  need to read back what it just wrote, but if Velero/Longhorn (or any
  verification step) does an immediate read-after-write check per object,
  expect spurious failures under concurrent uploads.
  Already ruled out: `--vfs-cache-mode full` on the gateway made no
  difference (identical timing both runs) — this isn't rclone-side caching,
  it's Drive's own `files.list` consistency window, so no client-side rclone
  flag fixes it. Untried: capping upload concurrency (fewer concurrent
  inserts may shrink the window), or just accepting ~15-20s before anything
  reads back what it wrote.
- **Multipart uploads aren't immune either.** A 20MiB multipart upload
  (5MiB parts) round-tripped and verified instantly with no lag. A 150MiB
  upload (10MiB parts) did hit the same "immediate GET after write returns
  `NoSuchKey`" symptom — so this isn't strictly a small-object-burst-only
  problem, it can happen after a single large `CompleteMultipartUpload`
  too. Sample size here is tiny (one run each), so treat "usually fine,
  sometimes not" as the honest current understanding, not "small objects
  bad, multipart fine."
- **Trap found via the above: `DELETE` on an object that isn't visible yet
  silently no-ops instead of erroring.** S3 semantics say deleting a
  nonexistent key returns success, so during the concurrent-burst test, a
  cleanup `DELETE` pass fired immediately after a batch of GETs had just
  failed with `NoSuchKey` — 4 of those 20 objects were still not visible to
  the gateway at that instant, so the "delete" for them was a no-op that
  reported success anyway, leaving them behind undetected until a `list`
  turned them up much later. For this project's real use case this matters
  most for backup-expiration/GC logic (Velero/Longhorn deleting old
  backups): don't trust a delete-success response as proof the object is
  actually gone if it could plausibly still be inside the visibility-lag
  window from being written.

## Non-goals

- This does not replace having *a* real S3-compatible target (R2) as a
  fallback/comparison — it's explored as a "use storage I already pay for"
  option, not because R2's free tier is insufficient.

## Quickstart

### 1. Create the Drive remote (milestone 1)

```sh
rclone config   # create a remote named "drive", type "drive"
rclone lsd drive:
rclone copy ./somefile.txt drive:test/
```

This produces `~/.config/rclone/rclone.conf`. Copy it into the repo root as
`rclone.conf` for local testing — it's gitignored, never commit it.

### 2. Run the gateway locally (milestones 2 & 3)

```sh
cp rclone.conf ./rclone.conf   # if not already there
cat > .env <<EOF
RCLONE_S3_ACCESS_KEY_ID=devkey
RCLONE_S3_SECRET_ACCESS_KEY=devsecret
EOF

docker compose up --build
```

Then, from another shell:

```sh
export AWS_ACCESS_KEY_ID=devkey
export AWS_SECRET_ACCESS_KEY=devsecret
aws --endpoint-url http://localhost:8080 s3 mb s3://test
aws --endpoint-url http://localhost:8080 s3 cp ./somefile.txt s3://test/
aws --endpoint-url http://localhost:8080 s3 ls s3://test/
aws --endpoint-url http://localhost:8080 s3 cp s3://test/somefile.txt ./roundtrip.txt
diff somefile.txt roundtrip.txt
aws --endpoint-url http://localhost:8080 s3 rm s3://test/somefile.txt
```

### 3. Publish the image

Pushing to `main` (or a `v*` tag) runs
`.github/workflows/docker-publish.yml`, which builds and pushes the image to
`ghcr.io/<owner>/<repo>` using the repo's built-in `GITHUB_TOKEN` — no extra
registry credentials to set up. Make the package public under the repo's
**Packages** settings if it needs to be pulled without auth.

### 4. Run in-cluster (milestone 4)

```sh
# real secret, not k8s/secret.example.yaml — see comments in that file
kubectl create secret generic gdrive-s3-gateway \
  --from-file=rclone.conf=./rclone.conf \
  --from-literal=access-key-id=CHANGE-ME \
  --from-literal=secret-access-key=CHANGE-ME

# edit k8s/deployment.yaml's image: to ghcr.io/<owner>/gdrive-s3-gateway:latest
kubectl apply -k k8s/
```

Milestones 5–7 (Velero round-trip, Longhorn round-trip, failure-mode checks)
are exercised against a real cluster and aren't part of this repo's files.
