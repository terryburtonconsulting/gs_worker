# gs_worker

HTTP service that executes PostScript via a long-lived GhostScript interpreter
and returns results as JSON. Built with Perl/Dancer2 and the GSAPI XS bindings.

## Endpoints

- `POST /gs` — Execute PostScript. Operates in one of two modes:

  **Simple mode** — pass a `ps` field containing the PostScript to run. Returns `rc`, `stderr`, and (when `capture_stdout` is true, the default) `stdout_b64` containing the base64-encoded device output.

  **Bbox+render mode** — pass a `bbox_ps` field together with one or more render templates in `render_ps`. The bbox pass runs first to determine the output dimensions; the resulting bbox values are then substituted into each render template before it is run. Returns the hi-res bbox coordinates and a `renders` array with one entry per template, each containing `stdout_b64`.

  An optional `pdf2svg` array of render indices may be supplied to convert selected PDF renders to SVG. The SVG backend is selected at build time (see *Docker*): Poppler's `pdftocairo` by default, or MuPDF when built in. The resulting SVG is returned as an `svg` field on the corresponding `renders` entry.

  `ps` and `bbox_ps` are mutually exclusive.

- `GET /healthcheck` — Returns 200 when the interpreter is ready.

## Assets

Application-specific PostScript (init scripts, fonts, resources) is loaded at
startup from the directory specified by the `ASSETS_DIR` environment variable
(default `/srv/assets`). An example `init.ps` is provided in `assets/`.

## Configuration

| Variable                | Default       | Purpose                                              |
|-------------------------|---------------|------------------------------------------------------|
| `ASSETS_DIR`            | `/srv/assets` | Path to init.ps, fonts, PostScript resources         |
| `REQUEST_TIMEOUT`       | `5`           | Watchdog timeout in seconds                          |
| `MAX_REQUESTS`          | `1000`        | Gracefully recycle workers after N requests          |
| `WORKERS`               | `4`           | Number of worker processes                           |
| `GS_RENDER_OUTPUT`      | `scratch`     | Output routing: `scratch` (spool file) or `stdout`   |
| `GS_SCRATCH_DIR`        | `/tmp/gs`     | Directory used when `GS_RENDER_OUTPUT=scratch`       |
| `GS_WORKER_AUTH_SECRET` | (none)        | 40-char hex for HMAC request authentication          |
| `GS_WORKER_AUTH_SKEW`   | `60`          | Clock skew tolerance for HMAC auth (seconds)         |

## Docker

| Build arg      | Purpose                                                                  |
|----------------|--------------------------------------------------------------------------|
| `ALPINE_VER`   | **Required.** Alpine base image tag.                                     |
| `GS_VER`       | **Required.** GhostScript release to build.                              |
| `GS_SHA256`    | Checksum for the GhostScript tarball; verified when set.                 |
| `GS_DRIVERS`   | GhostScript `--with-drivers` device list; omit to build all drivers.     |
| `MUPDF_VER`    | Build MuPDF for SVG at this version instead of using `pdftocairo`.       |
| `MUPDF_SHA256` | Checksum for the MuPDF tarball; verified when set.                       |

```bash
docker build --build-arg ALPINE_VER=<alpine_ver> --build-arg GS_VER=<gs_ver> -t gs_worker .
docker run -p 4000:4000 gs_worker

# With custom assets
docker run -p 4000:4000 -v /path/to/assets:/srv/assets:ro gs_worker
```

## License

AGPL-3.0 — see [LICENSE](LICENSE).

## Source availability

This repository — <https://github.com/terryburtonconsulting/gs_worker> — together
with the [Dockerfile](Dockerfile) it contains, constitutes the Corresponding
Source for the `gs_worker` container as required by AGPL-3.0 §13. The source for
the third-party components built into the container is available from the upstream
URLs listed in *Third-party components* below.

## GSAPI

The `GSAPI/` directory contains a vendored copy of the
[GSAPI](https://metacpan.org/pod/GSAPI) Perl XS module which provides bindings
to the GhostScript C API. GSAPI is licensed under the GNU General Public
License 2.0 or later.

## MUPDFAPI

The `MUPDFAPI/` directory contains the MUPDFAPI Perl XS module which provides
bindings to the MuPDF C API for PDF-to-SVG conversion. It is compiled into the
image when `MUPDF_VER` is set; MUPDFAPI is licensed under the GNU Affero
General Public License version 3.

## Third-party components

This service may be built against one or more of the following components:

| Component   | Upstream                                      |
|-------------|-----------------------------------------------|
| GhostScript | <https://github.com/ArtifexSoftware/ghostpdl> |
| MuPDF       | <https://mupdf.com/>                          |
| Poppler     | <https://poppler.freedesktop.org/>            |

The exact upstream tarball URLs, build flags, and any modifications applied are
recorded in the [Dockerfile](Dockerfile), which forms part of the Corresponding
Source for this work. GhostScript and MuPDF are built from unmodified upstream
sources; only build-time configuration (feature flags, unused sub-projects) is
adjusted.

