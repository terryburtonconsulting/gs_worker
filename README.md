# gs_worker

HTTP service that executes PostScript via a long-lived GhostScript interpreter
and returns results as JSON. Built with Perl/Dancer2 and the GSAPI XS bindings.

## Endpoints

- `POST /gs` — Execute PostScript. Operates in one of two modes:

  **Simple mode** — pass a `ps` field containing the PostScript to run. Returns `rc`, `stderr`, and (when `capture_stdout` is true, the default) `stdout_b64` containing the base64-encoded device output.

  **Bbox+render mode** — pass a `bbox_ps` field together with one or more render templates in `render_ps`. The bbox pass runs first to determine the output dimensions; the resulting bbox values are then substituted into each render template before it is run. Returns the hi-res bbox coordinates and a `renders` array with one entry per template, each containing `stdout_b64`.

  An optional `pdf2svg` array of render indices may be supplied to convert selected PDF renders to SVG in-process using MuPDF. The resulting SVG is returned as an `svg` field on the corresponding `renders` entry.

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
| `GS_WORKER_AUTH_SECRET` | (none)        | 40-char hex for HMAC request authentication          |
| `GS_WORKER_AUTH_SKEW`   | `60`          | Clock skew tolerance for HMAC auth (seconds)         |

## Docker

```bash
docker build -t gs_worker .
docker run -p 4000:4000 gs_worker

# With custom assets
docker run -p 4000:4000 -v /path/to/assets:/srv/assets:ro gs_worker
```

## License

AGPL-3.0 — see [LICENSE](LICENSE).

## Source availability

This project, together with the Dockerfile in this repository, constitutes the
Corresponding Source for the `gs_worker` container as required by AGPL-3.0 §13.
The source for the GhostScript and MuPDF components linked into the container
is available from the upstream URLs listed in *Third-party components* below, at
the versions pinned in the Dockerfile.

## GSAPI

The `GSAPI/` directory contains a vendored copy of the
[GSAPI](https://metacpan.org/pod/GSAPI) Perl XS module which provides bindings
to the GhostScript C API. GSAPI is licensed under the GNU General Public
License 2.0 or later.

## MUPDFAPI

The `MUPDFAPI/` directory contains the MUPDFAPI Perl XS module which provides
bindings to the MuPDF C API for PDF-to-SVG conversion. MUPDFAPI is licensed
under the GNU Affero General Public License version 3.

## Third-party components

This service is built against the following components, both licensed under the
GNU Affero General Public License version 3:

| Component   | Upstream                                      |
|-------------|-----------------------------------------------|
| GhostScript | <https://github.com/ArtifexSoftware/ghostpdl> |
| MuPDF       | <https://mupdf.com/>                          |

The exact upstream tarball URLs, build flags, and any modifications applied are
recorded in the [Dockerfile](Dockerfile), which forms part of the Corresponding
Source for this work. Both components are built from unmodified upstream
sources; only build-time configuration (feature flags, unused sub-projects) is
adjusted.

