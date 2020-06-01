#
# gs_worker - GhostScript rendering worker service
#
# Standalone Dockerfile for building the gs_worker service container.
#
# Build:
#   docker build --build-arg ALPINE_VER=<alpine_ver> --build-arg GS_VER=<gs_ver> -t gs_worker .
#
# Run:
#   docker run -p 4000:4000 gs_worker
#
# With custom assets (init.ps, fonts, PostScript resources, etc.):
#   docker run -p 4000:4000 -v /path/to/assets:/srv/assets:ro gs_worker
#
# Copyright (c) 2026 Terry Burton
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#

ARG ALPINE_VER=
ARG GS_VER=
ARG GS_SHA256=
ARG GS_DRIVERS=
ARG MUPDF_VER=
ARG MUPDF_SHA256=

FROM alpine:${ALPINE_VER}

ARG GS_VER
ARG GS_SHA256
ARG GS_DRIVERS
ARG MUPDF_VER
ARG MUPDF_SHA256

# Runtime dependencies
RUN apk update && apk add --no-cache \
    perl libgomp libgcc libjpeg-turbo libpng tiff \
    freetype cups-libs openjpeg jbig2dec tini

RUN if [ -z "${MUPDF_VER}" ]; then apk add --no-cache poppler-utils; fi

# Build dependencies
RUN apk add --no-cache \
    autoconf automake musl-dev gcc g++ make libtool wget \
    perl-dev libjpeg-turbo-dev libpng-dev tiff-dev \
    freetype-dev cups-dev openjpeg-dev zlib-dev jbig2dec-dev

# Install cpanm
RUN wget -O cpanmin.us https://cpanmin.us/ && perl cpanmin.us App::cpanminus && rm cpanmin.us

# Build and install GhostScript
WORKDIR /root
RUN set -eu; \
    : "${GS_VER:?GS_VER build arg is required}"; \
    wget -q -O ghostscript.tar.gz "https://github.com/ArtifexSoftware/ghostpdl/archive/refs/tags/ghostpdl-${GS_VER}.tar.gz"; \
    if [ -n "${GS_SHA256}" ]; then echo "${GS_SHA256}  ghostscript.tar.gz" | sha256sum -c -; fi; \
    mkdir gs && tar --strip-components 1 -C gs -xf ghostscript.tar.gz; \
    cd gs; \
    if [ -d gs/base ]; then cd gs; \
    elif [ -d base ]; then rm -rf gpdl xps pcl; \
    else echo "no GhostScript base/ directory in source tree" >&2; exit 1; fi; \
    sh ./autogen.sh >/dev/null 2>&1 || true; \
    test -f configure; \
    cp "$(find /usr/share -name config.guess | head -1)" .; \
    cp "$(find /usr/share -name config.sub   | head -1)" .; \
    ./configure CC="gcc -std=gnu17 -fpermissive -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=implicit-int" \
        --without-x --disable-cups --disable-fontconfig --disable-dbus --disable-gtk \
        ${GS_DRIVERS:+--with-drivers=$GS_DRIVERS}; \
    make -j "$(nproc)" soinstall || true; \
    test -e /usr/local/lib/libgs.so; \
    cd /root && rm -rf gs ghostscript.tar.gz

# Build and install MuPDF (minimal: PDF input + SVG output only, no fonts)
RUN set -eu; \
    if [ -n "${MUPDF_VER}" ]; then \
        wget -q -O mupdf.tar.gz "https://mupdf.com/downloads/archive/mupdf-${MUPDF_VER}-source.tar.gz"; \
        if [ -n "${MUPDF_SHA256}" ]; then echo "${MUPDF_SHA256}  mupdf.tar.gz" | sha256sum -c -; fi; \
        mkdir mupdf && tar --strip-components 1 -C mupdf -xf mupdf.tar.gz && cd mupdf \
     && rm -rf thirdparty/freetype thirdparty/harfbuzz thirdparty/zlib \
               thirdparty/libjpeg thirdparty/jbig2dec thirdparty/openjpeg \
               thirdparty/gumbo-parser thirdparty/freeglut thirdparty/curl \
               thirdparty/tesseract thirdparty/leptonica \
               thirdparty/zxing-cpp thirdparty/zint \
               thirdparty/brotli \
     && sed -i '1i XCFLAGS += -DTOFU -DTOFU_CJK -DTOFU_EMOJI -DTOFU_HISTORIC -DTOFU_SYMBOL -DTOFU_SIL -DTOFU_BASE14 -DFZ_ENABLE_XPS=0 -DFZ_ENABLE_SVG=0 -DFZ_ENABLE_CBZ=0 -DFZ_ENABLE_IMG=0 -DFZ_ENABLE_HTML=0 -DFZ_ENABLE_FB2=0 -DFZ_ENABLE_MOBI=0 -DFZ_ENABLE_EPUB=0 -DFZ_ENABLE_OFFICE=0 -DFZ_ENABLE_TXT=0 -DFZ_ENABLE_JPX=0 -DFZ_ENABLE_BROTLI=0 -DFZ_ENABLE_BARCODE=0 -DFZ_ENABLE_HYPHEN=0 -DFZ_ENABLE_OCR_OUTPUT=0 -DFZ_ENABLE_DOCX_OUTPUT=0 -DFZ_ENABLE_ODT_OUTPUT=0' Makerules \
     && make -j "$(nproc)" prefix=/usr/local \
          HAVE_GLUT=no HAVE_X11=no HAVE_CURL=no \
          USE_TESSERACT=no USE_ZXINGCPP=no USE_LIBARCHIVE=no \
          USE_EXTRACT=no USE_BROTLI=no USE_GUMBO=no USE_SYSTEM_LIBS=yes mujs=no \
          USE_SYSTEM_FREETYPE=yes USE_SYSTEM_ZLIB=yes \
          USE_SYSTEM_LIBJPEG=yes USE_SYSTEM_JBIG2DEC=yes USE_SYSTEM_OPENJPEG=yes \
          xps=no svg=no html=no shared=yes \
          install-shared-c \
     && cd /root && rm -rf mupdf mupdf.tar.gz; \
    fi

# Build and install GSAPI Perl XS binding
COPY GSAPI /root/GSAPI
RUN cpanm --notest --no-man-pages ./GSAPI && rm -rf GSAPI

# Build and install MUPDFAPI Perl XS binding
COPY MUPDFAPI /root/MUPDFAPI
RUN if [ -e /usr/local/include/mupdf/fitz.h ]; then cpanm --notest --no-man-pages ./MUPDFAPI; fi && rm -rf /root/MUPDFAPI

# Install Perl dependencies
RUN cpanm --notest --no-man-pages \
    Dancer2 \
    Dancer2::Template::Simple \
    Starman \
    JSON::XS \
    Capture::Tiny \
    Digest::SHA \
    File::pushd \
    Plack::Middleware::Timeout \
    Plack::Middleware::SizeLimit

# Clean up build dependencies
RUN apk del autoconf automake musl-dev gcc g++ make libtool \
    perl-dev libjpeg-turbo-dev libpng-dev tiff-dev freetype-dev cups-dev \
    openjpeg-dev zlib-dev jbig2dec-dev \
 && rm -rf /root/.cpanm /root/perl5 \
 && rm -rf /usr/local/include/ghostscript /usr/local/include/mupdf \
 && rm -rf /usr/local/share/ghostscript /usr/local/share/doc/ghostscript

# Application
RUN addgroup -S user && adduser -S user -G user

COPY gs_worker /srv/gs_worker
RUN chmod -R ugo+r /srv/gs_worker \
 && chmod ugo+x /srv/gs_worker/bin/app.psgi

COPY assets/init.ps.example /srv/assets/init.ps

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENV DANCER_ENVIRONMENT=production
ENV ASSETS_DIR=/srv/assets
EXPOSE 4000
USER user
WORKDIR /srv/gs_worker/bin
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
CMD ["plackup", "-s", "WatchdogStarman", "-I", "lib", "--port", "4000", "--access-log", "/dev/null", "app.psgi"]

HEALTHCHECK --interval=5s --timeout=3s --retries=3 --start-period=10s \
    CMD wget -U healthcheck -T 3 -O /dev/null -q http://127.0.0.1:4000/healthcheck || exit 1
