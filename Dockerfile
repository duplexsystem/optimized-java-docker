FROM clearlinux:latest AS builder

ARG swupd_args
# Move to latest Clear Linux release to ensure
# that the swupd command line arguments are
# correct
RUN swupd update --no-boot-update $swupd_args

RUN swupd bundle-add c-basic

RUN LOCATION=$(curl -s https://api.github.com/repos/zlib-ng/zlib-ng/releases/latest \
    | grep "tarball_url" \
    | awk '{ print $2 }' \
    | sed 's/,$//'       \
    | sed 's/"//g' )     \
    ; curl -L -o /tmp/zlib-ng.tar $LOCATION; \
    mkdir -p /tmp/; \
    tar --extract \
	      --file /tmp/zlib-ng.tar \
	      --directory "/tmp/"

RUN cd /tmp/zlib-ng-zlib-ng-*; \
    ./configure --zlib-compat; \
    make -j$(nproc); make install
    
RUN cd /

RUN LOCATION=$(curl -s https://api.github.com/repos/microsoft/mimalloc/tags | \
    grep -Eo '"tarball_url": "([^"]+)"' | \
    grep -v "win-m4" | \
    head -n 1 | \
    awk -F'"' '{print $4}'); \
    curl -L -o /tmp/mimalloc.tar $LOCATION; \
    mkdir -p /tmp/; \
    tar --extract --file /tmp/mimalloc.tar --directory "/tmp/"

RUN cd /tmp/microsoft-mimalloc-*; \
    mkdir -p out/release; \
    cd out/release; \
    cmake ../..; \
    make -j$(nproc); make install

# Grab os-release info from the minimal base image so
# that the new content matches the exact OS version
COPY --from=clearlinux/os-core:latest /usr/lib/os-release /

# Install additional content in a target directory
# using the os version from the minimal base
RUN source /os-release && \
    mkdir /install_root \
    && swupd os-install -V ${VERSION_ID} \
    --path /install_root --statedir /swupd-state \
    --bundles=os-core-update,libstdcpp,openssl,tzdata,fonts-basic,iproute2,sqlite,git,curl,sysadmin-basic,libX11client --no-boot-update
    
# For some Host OS configuration with redirect_dir on,
# extra data are saved on the upper layer when the same
# file exists on different layers. To minimize docker
# image size, remove the overlapped files before copy.
RUN mkdir /os_core_install
COPY --from=clearlinux/os-core:latest / /os_core_install/
RUN cd / && \
    find os_core_install | sed -e 's/os_core_install/install_root/' | xargs rm -d &> /dev/null || true

FROM clearlinux/os-core:latest

COPY --from=builder /install_root /

    
RUN rm -f /usr/lib64/libz.* /usr/lib64/pkgconfig/zlib.pc /usr/include/zlib.h /usr/include/zconf.h /usr/include/zlib_name_mangling.h /usr/lib64/libmimalloc.* /usr/lib64/pkgconfig/mimalloc.pc; \
    rm -rf /usr/lib64/mimalloc-* /usr/include/mimalloc-*

COPY --from=builder /usr/local/lib/libz.* /usr/local/lib64/libmimalloc.* /usr/local/lib64/mimalloc-* /usr/lib64/
COPY --from=builder /usr/local/include/zlib.h /usr/local/include/zconf.h /usr/local/include/zlib_name_mangling.h /usr/local/include/mimalloc-* /usr/include/
COPY --from=builder /usr/local/lib/pkgconfig/zlib.pc /usr/local/lib64/pkgconfig/mimalloc.pc /usr/lib64/pkgconfig/

ENV JAVA_HOME=/opt/java/graalvm
ENV PATH=$JAVA_HOME/bin:$PATH JAVA_VERSION=jdk-21+35LD_PRELOAD=usr/lib64/libmimalloc.so MIMALLOC_LARGE_OS_PAGES=1

RUN set -eux; \
	  curl -o /tmp/graalvm.tar.gz https://download.oracle.com/graalvm/21/latest/graalvm-jdk-21_linux-x64_bin.tar.gz; \
	  curl -o /tmp/graalvm.tar.gz.sha256 https://download.oracle.com/graalvm/21/latest/graalvm-jdk-21_linux-x64_bin.tar.gz.sha256; \
	  ESUM=$(cat /tmp/graalvm.tar.gz.sha256); \
	  echo "${ESUM} */tmp/graalvm.tar.gz" | sha256sum -c -; \
	  mkdir -p "$JAVA_HOME"; \
	  tar --extract \
	      --file /tmp/graalvm.tar.gz \
	      --directory "$JAVA_HOME" \
	      --strip-components 1 \
	      --no-same-owner \
	  ; \
    rm -f /tmp/graalvm.tar.gz /tmp/graalvm.tar.gz.sha256 ${JAVA_HOME}/lib/src.zip; \
    mkdir -p /etc/ld.so.conf.d; \
# https://github.com/docker-library/openjdk/issues/331#issuecomment-498834472
    find "$JAVA_HOME/lib" -name '*.so' -exec dirname '{}' ';' | sort -u > /etc/ld.so.conf.d/docker-openjdk.conf; \
    ldconfig; \
# https://github.com/docker-library/openjdk/issues/212#issuecomment-420979840
# https://openjdk.java.net/jeps/341
    java -Xshare:dump;

RUN echo Verifying install ...; \
    fileEncoding="$(echo 'System.out.println(System.getProperty("file.encoding"))' | jshell -s -)"; [ "$fileEncoding" = 'UTF-8' ]; rm -rf ~/.java; \
    echo javac --version; \ 
    javac --version; \
    echo java --version; \
    java --version; \
    echo Complete.

RUN useradd -d /home/container -m container

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

COPY /entrypoint.sh /entrypoint.sh
CMD [ "/bin/bash", "/entrypoint.sh" ]
