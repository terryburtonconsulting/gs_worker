#
# gs_worker.pm - GhostScript rendering worker service over HTTP
#
# Provides PostScript execution via GSAPI and PDF-to-SVG conversion
# via MUPDFAPI. Returns results as JSON.
# Application-specific assets (init.ps, fonts, etc.) are loaded from
# the assets directory at startup.
#
# Copyright (c) 2026 Terry Burton
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package gs_worker;

our $VERSION = '1.0';

use strict;
use warnings;
use Dancer2;
use GSAPI qw(:const);
use Capture::Tiny qw(capture_stdout);
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA qw(hmac_sha1_hex);
use Time::HiRes qw(time);
use Socket;
use Sys::Hostname;
use MUPDFAPI;

my $MY_IP = inet_ntoa(scalar gethostbyname(hostname()));
my $ASSETS_DIR            = $ENV{ASSETS_DIR}            || '/srv/assets';
my $GS_WORKER_AUTH_SECRET = $ENV{GS_WORKER_AUTH_SECRET} || '';
my $GS_WORKER_AUTH_SKEW   = $ENV{GS_WORKER_AUTH_SKEW}   || 60;

my $mupdf_ctx = MUPDFAPI::new_context();

my $gs;
my $gsstdout;
my $gsstderr;
my $gs_needs_init = 1;
my $healthy = 0;

init_gs();

sub init_gs {
    $gsstdout = $gsstderr = '';
    $gs_needs_init = 1;
    $healthy = 0;

    info "Creating GSAPI instance";
    $gs = GSAPI::new_instance();
    unless ($gs) {
        error "FATAL: GSAPI new_instance failed";
        exit(1);
    }

    debug "Wiring up GSAPI for output capture";
    # Capture PostScript-level I/O (print, =, stderr) via callbacks.
    # Device output (PDF/PNG via -sOutputFile=%stdout) bypasses these
    # and writes directly to fd 1 — captured separately by Capture::Tiny.
    GSAPI::set_stdio($gs, sub {"\n"}, sub {$gsstdout .= $_[0]; length $_[0]}, sub {$gsstderr .= $_[0]; length $_[0]});

    my $fontpath = "${ASSETS_DIR}/fonts";
    my @args = ("-dSAFER", "--permit-devices=*", "-dNOEPS", "--permit-file-read=${ASSETS_DIR}/*");
    push @args, "-sFONTPATH=${fontpath}" if -d $fontpath;

    info "Initialising GSAPI";
    my $rc = GSAPI::init_with_args($gs, @args);
    if ($rc != 0) {
        error "FATAL: GSAPI init failed rc=$rc ($gsstderr)";
        exit(1);
    }

    debug "Setting ASSETS_DIR in VM";
    $rc = GSAPI::run_string($gs, "/ASSETS_DIR (${ASSETS_DIR}) def");
    if ($rc != 0) {
        error "FATAL: Failed to set ASSETS_DIR rc=$rc ($gsstderr)";
        exit(1);
    }

    my $init_ps = "${ASSETS_DIR}/init.ps";
    if (-f $init_ps) {
        info "Running init.ps from assets";
        $rc = GSAPI::run_file($gs, $init_ps);
        if ($rc != 0) {
            error "FATAL: init.ps failed rc=$rc ($gsstderr)";
            exit(1);
        }
    }

    $gs_needs_init = 0;
    $healthy = 1;
    info "Initialised and ready";
}

sub reinit_gs {
    warning "Reinitialising GSAPI";
    if ($gs) {
        eval { GSAPI::exit($gs) };
        eval { GSAPI::delete_instance($gs) };
    }
    $gs = undef;
    init_gs();
}

sub check_gs_rc {
    my $rc = shift;
    if ($rc <= -100) {
        error "GSAPI fatal error rc=$rc, flagging for reinit";
        $healthy = 0;
        if ($gs) {
            eval { GSAPI::exit($gs) };
            eval { GSAPI::delete_instance($gs) };
        }
        $gs_needs_init = 1;
        return 0;
    }
    return $rc == 0;
}

sub check_auth {
    my ($signed_content) = @_;
    return if $GS_WORKER_AUTH_SECRET eq '';
    my $auth = request->header('X-Worker-Auth') // '';
    my ($nonce, $sig) = $auth =~ /^(\d+\.\S+) ([0-9a-f]+)$/;
    unless (defined $nonce && defined $sig) {
        debug "Auth failed: invalid format";
        halt(json_response({error => 'auth_failed', message => 'invalid format'}, 403));
    }
    my ($ts) = $nonce =~ /^(\d+)\./;
    unless (defined $ts && abs(time() - $ts) <= $GS_WORKER_AUTH_SKEW) {
        debug "Auth failed: clock skew";
        halt(json_response({error => 'auth_failed', message => 'clock skew'}, 403));
    }
    unless ($sig eq hmac_sha1_hex($nonce . $signed_content, $GS_WORKER_AUTH_SECRET)) {
        debug "Auth failed: bad signature";
        halt(json_response({error => 'auth_failed', message => 'bad signature'}, 403));
    }
    return;
}

sub json_response {
    my ($data, $code) = @_;
    status($code) if $code;
    content_type 'application/json';
    response_header 'X-Served-By' => $MY_IP;
    return encode_json($data);
}

sub _cid_logger {
    my $cid = request->header('X-Correlation-ID') // '';
    $cid = substr($cid, 0, 8) if $cid =~ /^[0-9a-f]{32}$/;
    $cid = '' unless $cid =~ /^[0-9a-f]{8}$/;
    return $cid ne '' ? sub { "[$cid] $_[0]" } : sub { $_[0] };
}

get '/healthcheck' => sub {
    if ($healthy) {
        return;
    } else {
        debug "Healthcheck failed: healthy=$healthy";
        status 503;
        halt('Unavailable');
    }
};

# Reset GS state, reinitialising if necessary.  Returns undef on success,
# or a JSON error response string on failure.
sub _reset_gs {
    my ($L) = @_;

    if ($gs_needs_init) {
        debug $L->("GS needs init, reinitialising");
        reinit_gs();
    }

    unless ($healthy) {
        error $L->("GS unavailable");
        return json_response({error => 'gs_unavailable', message => 'GhostScript interpreter not available'}, 503);
    }

    $gsstdout = $gsstderr = '';
    my $rc = GSAPI::run_string($gs, "/GS_WORKER_RESET where { pop GS_WORKER_RESET } if");
    unless (check_gs_rc($rc)) {
        debug $L->("State reset failed, reinitialising");
        reinit_gs();
        $gsstdout = $gsstderr = '';
        $rc = GSAPI::run_string($gs, "/GS_WORKER_RESET where { pop GS_WORKER_RESET } if");
        unless (check_gs_rc($rc)) {
            error $L->("State reset failed after reinit rc=$rc");
            return json_response({rc => $rc, stderr => $gsstderr, error => 'gs_fatal', healthy => \0}, 503);
        }
    }
    return undef;
}

# Run PostScript with stdout capture.  Returns ($rc, $stdout_data, $stderr).
# On fatal GS error, returns a JSON error response string instead.
sub _run_ps {
    my ($L, $ps, $capture) = @_;
    $capture //= 1;

    $gsstdout = $gsstderr = '';
    my $rc;
    my $stdout_data = '';

    if ($capture) {
        $stdout_data = capture_stdout {
            $rc = GSAPI::run_string($gs, $ps);
        };
    } else {
        $rc = GSAPI::run_string($gs, $ps);
    }

    if ($rc != 0 && $rc <= -100) {
        check_gs_rc($rc);
        return json_response({rc => $rc, stderr => $gsstderr, error => 'gs_fatal', healthy => \0}, 503);
    }

    return ($rc, $stdout_data, $gsstderr);
}

#
# PostScript execution endpoint — POST /gs
#
# Two modes determined by which field is present in the JSON body:
#
#
# ── Simple mode (ps field) ─────────────────────────────────────────
#
#   Runs arbitrary PostScript once and returns the result.
#
#   Parameters:
#     ps              - PostScript string to execute (required)
#     capture_stdout  - whether to capture device output (default: 1)
#
#   Returns: { rc, stderr, stdout_b64? }
#     stderr is always included (may contain device output like
#     %%BoundingBox that the caller needs to parse).
#
#   Example — run PostScript with bbox device (no stdout capture):
#     { "ps": "<< /OutputDevice /bbox >> setpagedevice ... showpage",
#       "capture_stdout": 0 }
#
#   Example — render to PNG and capture the output:
#     { "ps": "<< /OutputDevice /pngalpha /OutputFile (%stdout)
#              /PageSize [100 100] >> setpagedevice ... showpage" }
#
#
# ── Bbox+render mode (bbox_ps field) ──────────────────────────────
#
#   Renders PostScript content whose output dimensions are unknown.
#
#   The problem: to render content to a correctly-sized page, you must
#   first discover its bounding box.  GhostScript's bbox device reports
#   dimensions via %%BoundingBox DSC comments in stderr, but does not
#   expose them to PostScript — so a second (render) pass is needed.
#
#   This endpoint runs the bbox pass, parses the bounding box from
#   stderr, computes page dimensions and translations, substitutes
#   these into render PostScript templates, then runs each render pass
#   with stdout capture.
#
#   The bbox device only handles first-quadrant coordinates.  Content
#   extending into negative coordinates (e.g. quiet zones) is shifted
#   positive by page_offset in the bbox PostScript.  The computed
#   translations reverse this shift for the render passes.
#
#   Parameters:
#     bbox_ps       - PostScript for the bbox pass (required).
#                     Must use the bbox device with PageOffset set to
#                     [page_offset, page_offset] to shift content into
#                     the first quadrant.
#     render_ps     - PostScript template(s) for render passes.
#                     String (one render), array (multiple), or omitted
#                     (bbox-only — returns dimensions without rendering).
#                     Templates contain placeholder tokens (see below)
#                     that are substituted with bbox-derived values.
#     page_offset   - Coordinate shift applied in bbox_ps (default: 0).
#                     Must match the PageOffset used in bbox_ps.
#     max_canvas    - Max allowed dimension in points (default: 0 = no
#                     limit).  If bbw or bbh exceeds this, returns
#                     bbox_error: 'canvas_too_large' and skips renders.
#     pad_factor_x  - Proportional padding as fraction of bbox width
#     pad_factor_y    (default: 0).  pad = int(bbw * factor) + constant.
#     pad_constant  - Fixed padding in points added to proportional
#                     padding (default: 0).
#
#   Padding adds whitespace margin for bitmap output.  For formats that
#   don't need padding (e.g. PDF), set factors and constant to 0 (or
#   omit them) and use BBOX_WIDTH/BBOX_HEIGHT for page size.
#
#   Template tokens (substituted into render_ps before execution):
#
#   All values are derived from the hi-res bounding box
#   (%%HiResBoundingBox) for maximum precision.
#
#     PAGE_WIDTH, PAGE_HEIGHT
#       Padded page dimensions: bbw + int(bbw * pad_factor_x) + pad_constant.
#       Use for device PageSize where margin is wanted.
#
#     BBOX_WIDTH, BBOX_HEIGHT
#       Raw bounding box dimensions (no padding).
#       Use for device PageSize for a tight-fit page.
#
#     TRANSLATE_X, TRANSLATE_Y
#       Translation to position content at the page origin:
#       page_offset - bbox_origin.  Reverses the bbox coordinate shift.
#       Use for unpadded output where content fills the page exactly.
#
#     PADDED_TRANSLATE_X, PADDED_TRANSLATE_Y
#       Translation scaled to the padded page: translate * page / bbox.
#       Centres content within the padded area.
#
#   Tokens are matched as bare words only — PostScript name literals
#   like /TRANSLATE_X are not affected by substitution.
#
#   Returns: { rc, bbx1hr, bby1hr, bbx2hr, bby2hr,
#              renders: [{ stdout_b64? }, ...] }
#     Only the hi-res bounding box is returned.  The caller can
#     derive integer bbox via floor(x1hr), floor(y1hr),
#     ceil(x2hr), ceil(y2hr) and dimensions from those.
#     stderr is only included in error responses.
#   On bbox failure: { rc, bbox_error: 'bbox_failed', stderr }
#   On canvas exceeded: { rc, bbox_error: 'canvas_too_large', stderr,
#                         bbx1hr..bby2hr, max_canvas }
#   On render failure: { rc, render_error: <index>, stderr }
#     render_error is the 1-based render pass index.
#     stderr is from the failing render pass only.
#     No successful render data is returned.
#
#   Example — bbox pass then render to PNG (padded) and PDF (tight):
#
#     { "bbox_ps":  "<< /PAGEDEVICE << /OutputDevice /bbox
#                      /PageOffset [3000 3000] >> ... >> HANDLER",
#       "render_ps": [
#         "<< /PAGEDEVICE << /OutputDevice /pngalpha
#            /OutputFile (%stdout)
#            /PageSize [PAGE_WIDTH PAGE_HEIGHT] >>
#            /TRANSLATE_X PADDED_TRANSLATE_X
#            /TRANSLATE_Y PADDED_TRANSLATE_Y ... >> HANDLER",
#         "<< /PAGEDEVICE << /OutputDevice /pdfwrite
#            /OutputFile (%stdout)
#            /PageSize [BBOX_WIDTH BBOX_HEIGHT] >>
#            /TRANSLATE_X TRANSLATE_X
#            /TRANSLATE_Y TRANSLATE_Y ... >> HANDLER"
#       ],
#       "page_offset": 3000,
#       "max_canvas": 2592,
#       "pad_factor_x": 0.25, "pad_factor_y": 0.25,
#       "pad_constant": 10 }
#
post '/gs' => sub {
    my $t0 = time();
    my $L = _cid_logger();

    my $params;
    eval { $params = decode_json(request->body) };
    if ($@) {
        debug $L->("Invalid JSON: $@");
        return json_response({error => 'invalid_json', message => "$@"}, 400);
    }

    my $bbox_ps = $params->{bbox_ps};
    my $ps      = $params->{ps};

    unless ((defined $bbox_ps && length $bbox_ps) || (defined $ps && length $ps)) {
        return json_response({error => 'missing_ps', message => 'ps or bbox_ps field is required'}, 400);
    }
    if (defined $ps && defined $bbox_ps) {
        return json_response({error => 'conflicting_params', message => 'ps and bbox_ps are mutually exclusive'}, 400);
    }

    check_auth($bbox_ps // $ps);

    # --- Simple mode: run once and return ---
    if (defined $ps) {
        debug $L->("Processing /gs simple request");

        my $err = _reset_gs($L);
        return $err if $err;

        my $capture = $params->{capture_stdout} // 1;
        my ($rc, $stdout_data, $stderr) = _run_ps($L, $ps, $capture);
        return $rc unless ref \$rc eq 'SCALAR';

        my $response = { rc => $rc + 0, stderr => $stderr };
        $response->{stdout_b64} = encode_base64($stdout_data, '') if $capture && length $stdout_data;

        if ($rc != 0) {
            info $L->(sprintf('/gs rc=%d in %.1fms', $rc, (time() - $t0) * 1000));
            return json_response($response, 500);
        }

        info $L->(sprintf('/gs rc=0 stdout=%d bytes in %.1fms', length($stdout_data), (time() - $t0) * 1000));
        return json_response($response);
    }

    # --- Bbox+render mode ---
    debug $L->("Processing /gs bbox+render request");

    my $render_ps_param = $params->{render_ps};
    my @render_templates;
    if (defined $render_ps_param) {
        @render_templates = ref $render_ps_param eq 'ARRAY' ? @$render_ps_param : ($render_ps_param);
    }

    my $max_canvas   = $params->{max_canvas}   // 0;
    my $page_offset  = $params->{page_offset}  // 0;
    my $pad_factor_x = $params->{pad_factor_x} // 0;
    my $pad_factor_y = $params->{pad_factor_y} // 0;
    my $pad_constant = $params->{pad_constant} // 0;

    my $err = _reset_gs($L);
    return $err if $err;

    debug $L->("Running bbox pass");
    my ($rc, undef, $bbox_stderr) = _run_ps($L, $bbox_ps, 0);
    return $rc unless ref \$rc eq 'SCALAR';

    my ($bbx1, $bby1, $bbx2, $bby2) = $bbox_stderr =~ m/%%BoundingBox:\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/;
    unless (defined $bbx1) {
        info $L->(sprintf('/gs bbox failed in %.1fms', (time() - $t0) * 1000));
        return json_response({rc => $rc + 0, bbox_error => 'bbox_failed', stderr => $bbox_stderr}, 200);
    }

    my $bbw = $bbx2 - $bbx1;
    my $bbh = $bby2 - $bby1;

    my ($bbx1hr, $bby1hr, $bbx2hr, $bby2hr) = $bbox_stderr =~ m/%%HiResBoundingBox:\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/;
    ($bbx1hr, $bby1hr, $bbx2hr, $bby2hr) = map { $_ + 0 } ($bbx1hr // $bbx1, $bby1hr // $bby1, $bbx2hr // $bbx2, $bby2hr // $bby2);

    if ($max_canvas > 0 && ($bbw > $max_canvas || $bbh > $max_canvas)) {
        info $L->(sprintf('/gs canvas %dx%d exceeds %d in %.1fms', $bbw, $bbh, $max_canvas, (time() - $t0) * 1000));
        return json_response({rc => 0, bbox_error => 'canvas_too_large', stderr => $bbox_stderr,
                              bbx1hr => $bbx1hr, bby1hr => $bby1hr,
                              bbx2hr => $bbx2hr, bby2hr => $bby2hr,
                              max_canvas => $max_canvas + 0}, 200);
    }

    # Hi-res bbox dimensions and translation
    my $bbwhr = $bbx2hr - $bbx1hr;
    my $bbhhr = $bby2hr - $bby1hr;
    my $translate_x = $page_offset - $bbx1hr;
    my $translate_y = $page_offset - $bby1hr;

    # Page dimensions with optional padding
    my $pad_x = int($bbwhr * $pad_factor_x) + $pad_constant;
    my $pad_y = int($bbhhr * $pad_factor_y) + $pad_constant;
    my $page_w = $bbwhr + $pad_x;
    my $page_h = $bbhhr + $pad_y;

    # Padded translation (scaled proportionally to padded page dimensions)
    my $padded_tx = $bbwhr > 0 ? ($translate_x * $page_w / $bbwhr) : $translate_x;
    my $padded_ty = $bbhhr > 0 ? ($translate_y * $page_h / $bbhhr) : $translate_y;

    # --- Render passes ---
    my @renders;

    for my $i (0..$#render_templates) {
        my $final_ps = $render_templates[$i];
        # Substitute bbox-derived values into render template.
        # Negative lookbehind (?<!/) prevents matching PostScript name
        # literals like /TRANSLATE_X — only bare tokens are replaced.
        $final_ps =~ s/(?<!\/)PAGE_WIDTH\b/$page_w/g;
        $final_ps =~ s/(?<!\/)PAGE_HEIGHT\b/$page_h/g;
        $final_ps =~ s/(?<!\/)PADDED_TRANSLATE_X\b/$padded_tx/g;
        $final_ps =~ s/(?<!\/)PADDED_TRANSLATE_Y\b/$padded_ty/g;
        $final_ps =~ s/(?<!\/)TRANSLATE_X\b/$translate_x/g;
        $final_ps =~ s/(?<!\/)TRANSLATE_Y\b/$translate_y/g;
        $final_ps =~ s/(?<!\/)BBOX_WIDTH\b/$bbwhr/g;
        $final_ps =~ s/(?<!\/)BBOX_HEIGHT\b/$bbhhr/g;

        $err = _reset_gs($L);
        return $err if $err;

        debug $L->("Running render pass $i");
        my ($rrc, $stdout_data, $render_stderr) = _run_ps($L, $final_ps, 1);
        return $rrc unless ref \$rrc eq 'SCALAR';

        my $render = {};
        $render->{stdout_b64} = encode_base64($stdout_data, '') if length $stdout_data;

        if ($rrc != 0) {
            info $L->(sprintf('/gs render %d of %d rc=%d in %.1fms', $i, scalar @render_templates, $rrc, (time() - $t0) * 1000));
            return json_response({rc => $rrc, render_error => $i + 1, stderr => $render_stderr}, 500);
        }

        # Render completed (rc=0) but produced no output — PostScript error
        # caught by a stopped handler that prevented showpage from executing
        if (!length($stdout_data) && length($render_stderr)) {
            info $L->(sprintf('/gs render %d of %d empty output in %.1fms', $i, scalar @render_templates, (time() - $t0) * 1000));
            return json_response({rc => 0, render_error => $i + 1, stderr => $render_stderr}, 200);
        }

        push @renders, $render;
    }

    # --- PDF to SVG conversion (via MuPDF) ---
    my $pdf2svg = $params->{pdf2svg};
    if ($pdf2svg && ref $pdf2svg eq 'ARRAY') {
        for my $idx (@$pdf2svg) {
            next unless $idx >= 0 && $idx <= $#renders && $renders[$idx]{stdout_b64};
            debug $L->("Converting render $idx PDF to SVG");
            my $pdf = decode_base64($renders[$idx]{stdout_b64});
            eval { $renders[$idx]{svg} = MUPDFAPI::pdf_to_svg($mupdf_ctx, $pdf) };
            if ($@) {
                error $L->("pdf2svg failed for render $idx: $@");
            }
        }
    }

    my $total_bytes = 0;
    $total_bytes += length($_->{stdout_b64} // '') for @renders;

    info $L->(sprintf('/gs bbox+render rc=0 bbox=%dx%d renders=%d stdout=%d bytes in %.1fms',
        $bbw, $bbh, scalar @renders, $total_bytes, (time() - $t0) * 1000));

    return json_response({
        rc      => 0,
        bbx1hr  => $bbx1hr, bby1hr  => $bby1hr,
        bbx2hr  => $bbx2hr, bby2hr  => $bby2hr,
        renders => \@renders,
    });
};

1;
