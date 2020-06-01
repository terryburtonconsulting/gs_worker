/*
 * MUPDFAPI.xs - Perl XS bindings for MuPDF PDF-to-SVG conversion
 *
 * Copyright (c) 2026 Terry Burton
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include <mupdf/fitz.h>

/*
 * MUPDFAPI - Perl XS bindings for MuPDF PDF-to-SVG conversion
 *
 * Provides a minimal API: create a reusable context once, then call
 * pdf_to_svg() with PDF bytes to get SVG bytes back.  All memory is
 * managed through MuPDF's fz_context allocator.
 */

typedef struct {
    fz_context *ctx;
} mupdfapi_context;

typedef mupdfapi_context *MUPDFAPI__context;

MODULE = MUPDFAPI		PACKAGE = MUPDFAPI

MUPDFAPI::context
new_context()
  PROTOTYPE:
  PREINIT:
      mupdfapi_context *mctx;
  CODE:
      Newxz(mctx, 1, mupdfapi_context);
      mctx->ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
      if (!mctx->ctx) {
          Safefree(mctx);
          croak("MUPDFAPI: cannot create fz_context");
      }
      fz_register_document_handlers(mctx->ctx);
      RETVAL = mctx;
  OUTPUT:
      RETVAL

void
drop_context(mctx)
        MUPDFAPI::context mctx
    PROTOTYPE: $
    CODE:
        if (mctx) {
            if (mctx->ctx)
                fz_drop_context(mctx->ctx);
            Safefree(mctx);
        }

SV *
_pdf_to_svg_raw(mctx, pdf_sv)
        MUPDFAPI::context mctx
        SV *pdf_sv
    PROTOTYPE: $$
    PREINIT:
        fz_context *ctx;
        fz_buffer *pdf_buf = NULL;
        fz_buffer *svg_buf = NULL;
        fz_document *doc = NULL;
        fz_document_writer *writer = NULL;
        fz_page *page = NULL;
        fz_device *dev = NULL;
        unsigned char *svg_data;
        size_t svg_len;
        STRLEN pdf_len;
        const char *pdf_ptr;
    CODE:
        ctx = mctx->ctx;
        pdf_ptr = SvPV(pdf_sv, pdf_len);

        fz_try(ctx) {
            pdf_buf = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)pdf_ptr, pdf_len);
            doc = fz_open_document_with_buffer(ctx, ".pdf", pdf_buf);

            svg_buf = fz_new_buffer(ctx, 4096);
            writer = fz_new_document_writer_with_buffer(ctx, svg_buf, "svg", "");

            page = fz_load_page(ctx, doc, 0);
            fz_rect box = fz_bound_page(ctx, page);

            dev = fz_begin_page(ctx, writer, box);
            fz_run_page(ctx, page, dev, fz_identity, NULL);
            fz_end_page(ctx, writer);
            fz_close_document_writer(ctx, writer);

            svg_len = fz_buffer_storage(ctx, svg_buf, &svg_data);
            RETVAL = newSVpvn((const char *)svg_data, svg_len);
        }
        fz_always(ctx) {
            fz_drop_page(ctx, page);
            fz_drop_document(ctx, doc);
            fz_drop_document_writer(ctx, writer);
            fz_drop_buffer(ctx, pdf_buf);
            fz_drop_buffer(ctx, svg_buf);
        }
        fz_catch(ctx) {
            croak("MUPDFAPI: %s", fz_caught_message(ctx));
        }
    OUTPUT:
        RETVAL
