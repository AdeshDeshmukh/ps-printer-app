FROM fedora:41 AS builder

RUN dnf install -y 'dnf-command(builddep)' \
    && dnf --enablerepo=\*source* builddep -y libcupsfilters libppd \
    && dnf install -y \
    gcc \
    gcc-c++ \
    make \
    which \
    autoconf \
    automake \
    libtool \
    gettext-devel \
    pkgconf-pkg-config \
    git \
    cups-devel \
    libjpeg-turbo-devel \
    libpng-devel \
    libtiff-devel \
    libjxl-devel \
    libexif-devel \
    libusb1-devel \
    avahi-devel \
    gnutls-devel \
    pam-devel \
    qpdf-devel \
    poppler-devel \
    zlib-devel \
    foomatic-db \
    foomatic-db-ppds \
    && dnf clean all

WORKDIR /build

RUN git clone --depth 1 --recurse-submodules https://github.com/OpenPrinting/libcups.git \
    && cd libcups \
    && ./configure --prefix=/usr --libdir=/usr/lib64 \
    && make -j$(nproc) \
    && make install

COPY .github/patches/pappl-listener-limit.patch /build/pappl-listener-limit.patch
RUN git clone --depth 1 -b v1.4.13 https://github.com/michaelrsweet/pappl.git \
    && cd pappl \
    && test "$(git rev-parse HEAD)" = 33e5c2fd340d4b65631e60df235ae744551df8d5 \
    && git apply /build/pappl-listener-limit.patch \
    && ./configure --prefix=/usr --libdir=/usr/lib64 --enable-libusb --with-dnssd=avahi \
    && make -j$(nproc) \
    && make install

RUN git clone --depth 1 --recurse-submodules https://github.com/michaelrsweet/pdfio.git \
    && cd pdfio \
    && ./configure --prefix=/usr --libdir=/usr/lib64 \
    && make -j$(nproc) \
    && make install

RUN git clone --depth 1 https://github.com/OpenPrinting/libcupsfilters.git \
    && cd libcupsfilters \
    && ./autogen.sh \
    && ./configure --prefix=/usr --libdir=/usr/lib64 --disable-mutool \
    && make -j$(nproc) \
    && make install

RUN git clone --depth 1 https://github.com/OpenPrinting/libppd.git \
    && cd libppd \
    && ./autogen.sh \
    && ./configure --prefix=/usr --libdir=/usr/lib64 --disable-mutool \
    && make -j$(nproc) \
    && make install

RUN git clone --depth 1 https://github.com/OpenPrinting/pappl-retrofit.git \
    && cd pappl-retrofit \
    && ./autogen.sh \
    && ./configure --prefix=/usr --libdir=/usr/lib64 \
    && make -j$(nproc) \
    && make install

COPY . /build/ps-printer-app
WORKDIR /build/ps-printer-app
RUN make -j$(nproc) && make install DESTDIR=/build/rootfs

FROM quay.io/fedora/fedora-minimal:41

RUN microdnf install -y \
    cups \
    cups-libs \
    libusb1 \
    libpng \
    libjpeg-turbo \
    libtiff \
    libjxl \
    libexif \
    avahi-libs \
    gnutls \
    qpdf-libs \
    poppler \
    foomatic-db \
    foomatic-db-ppds \
    shadow-utils \
    && microdnf clean all

COPY --from=builder /usr/lib64/libcups3* /usr/lib64/
COPY --from=builder /usr/lib64/libpappl* /usr/lib64/
COPY --from=builder /usr/lib64/libpdfio* /usr/lib64/
COPY --from=builder /usr/lib64/libcupsfilters* /usr/lib64/
COPY --from=builder /usr/lib64/libppd* /usr/lib64/
COPY --from=builder /usr/lib64/libpappl-retrofit* /usr/lib64/
COPY --from=builder /build/rootfs/ /

RUN ldconfig

RUN useradd -r -u 1001 -g lp -d /var/run/ps-printer-app -s /sbin/nologin printer-app \
    && mkdir -p /var/run/ps-printer-app /var/spool/ps-printer-app /var/lib/ps-printer-app \
    && chown -R 1001:lp /var/run/ps-printer-app /var/spool/ps-printer-app /var/lib/ps-printer-app

# Fedora reserves some CUPS backends for root. Grant the printer app's group
# access to its own copies while preserving the packaged executables.
ENV BACKEND_DIR=/usr/libexec/ps-printer-app/backend
RUN install -d -m 0755 "$BACKEND_DIR" \
    && cp -a /usr/lib/cups/backend/. "$BACKEND_DIR/" \
    && chgrp lp "$BACKEND_DIR/ipp" "$BACKEND_DIR/lpd" "$BACKEND_DIR/usb" \
    && chmod g+x "$BACKEND_DIR/ipp" "$BACKEND_DIR/lpd" "$BACKEND_DIR/usb"

USER 1001:lp
WORKDIR /var/run/ps-printer-app

EXPOSE 8000

ENTRYPOINT ["/usr/bin/ps-printer-app"]
CMD ["-o", "server-port=8000", "server"]
