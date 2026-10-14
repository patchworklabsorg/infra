# Runs inside the chrislusf/seaweedfs container as its entrypoint (`sh /krater/storage-start.sh`).
# Ported from Krater's docker-compose.yml `storage` service; keep the two in step. The S3 gateway reads
# its credentials from a JSON file, written here from env so no secret lands in the Nix store.
#
# Env (set by the krater-storage unit): S3_ACCESS_KEY, S3_SECRET_KEY.
set -eu

umask 077
printf '{"identities":[{"name":"krater","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","List","Tagging","Write"]}]}' \
  "$S3_ACCESS_KEY" "$S3_SECRET_KEY" > /tmp/s3.json
# -volume.max=0 sizes the volume limit from free disk. The default (8) is used up by the first collections, after
# which a new bucket can't get a volume and every upload to it fails with a 500.
exec weed server -dir=/data -volume.max=0 -master.volumeSizeLimitMB=1024 -s3 -s3.port=8333 -s3.config=/tmp/s3.json
