# Map Platform Production Deployment

`compose.yaml` is the production deployment lock for the map platform. It pins
the API/maintenance control plane and the signed-map worker to immutable GHCR
digests and passes the worker digest into the producer identity. The two pins
may match, but remain separate so an approval-only control-plane release can
advance without replacing a hardware-tested worker. Coolify secrets remain
outside Git.

## One-time Coolify configuration

Update the existing `open-bike-computer-map-platform` resource rather than
creating a new resource, so its domain and `map-platform-data` volume remain
attached.

- Build pack: `Docker Compose`
- Base directory: `/`
- Docker Compose location: `/deploy/map-platform/compose.yaml`
- Branch: `main`
- Auto deploy: enabled
- Watch path: `deploy/map-platform/compose.yaml`

Keep the existing secret and runtime variables in Coolify. The production
Compose no longer reads `MAP_PLATFORM_API_IMAGE`,
`MAP_PLATFORM_WORKER_IMAGE`, or `MAP_PLATFORM_MAINTENANCE_IMAGE`; remove those
three values after the first successful deployment to avoid presenting stale
configuration as active.

The initial worker lock points at the image already running successfully in
production. Its control-plane lock contains the same backend revision currently
deployed from `main`, so changing the Compose location does not introduce a new
worker binary.

## Promotion flow

The `Map Platform Image` workflow builds and attests candidate images. After a
successful build from `main`, it opens or refreshes the automation-owned
`deploy/map-platform-production` pull request with the new control-plane digest
and source commit. When the Git range changes an input used by the signed worker
identity, the same PR also advances the worker pin. Manual workflow dispatches
conservatively propose both pins for explicit review. The workflow never changes
production directly.

Review and merge that promotion pull request when the candidate is ready. The
merge changes `compose.yaml`, which matches the Coolify watch path and deploys
the exact pinned image. A promotion-only merge does not start another image
build, so the workflow cannot loop.

GitHub suppresses workflow events caused by `GITHUB_TOKEN`, so the promotion
job explicitly dispatches `ci.yml` for the promotion commit after opening or
refreshing the pull request. This keeps the automation on the least-privileged
repository token without requiring a personal access token.

Validate the lock locally with:

```sh
python3 deploy/map-platform/update_image.py \
  deploy/map-platform/compose.yaml \
  --check

MAP_PLATFORM_DOWNLOAD_SECRET=ci-download-secret \
MAP_PLATFORM_INSTALLATION_SECRET=ci-installation-secret-32-bytes-minimum \
MAP_PLATFORM_TRUSTED_PROXY_CIDRS=172.16.0.0/12 \
docker compose -f deploy/map-platform/compose.yaml config
```

## Rollback

Revert the promotion commit or open a new promotion pull request restoring a
previously known-good digest. Git history records the exact source commit and
image used by every deployment. Coolify's rollback remains available for
incident response, but follow it with a Git revert so declared production state
matches the running state.
