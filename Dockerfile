############################################################
# Dockerfile to build NGINX REVERSE PROXY
# Based on OpenResty on Ubuntu
# https://github.com/openresty/docker-openresty
############################################################

FROM ubuntu:16.10
MAINTAINER Chicory <dev@chicory.co>

# Docker Build Arguments
ARG RESTY_VERSION="1.11.2.2"
ARG RESTY_LUAROCKS_VERSION="2.3.0"
ARG RESTY_OPENSSL_VERSION="1.0.2j"
ARG RESTY_PCRE_VERSION="8.39"
ARG RESTY_J="1"
ARG RESTY_CONFIG_OPTIONS="\
    --with-file-aio \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_geoip_module=dynamic \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_image_filter_module=dynamic \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_xslt_module=dynamic \
    --with-ipv6 \
    --with-mail \
    --with-mail_ssl_module \
    --with-md5-asm \
    --with-pcre-jit \
    --with-sha1-asm \
    --with-stream \
    --with-stream_ssl_module \
    --with-threads \
    "
ARG LUAROCKS_CONFIG_OPTIONS="\
    --prefix=/usr/local/openresty/luajit \
    --with-lua=/usr/local/openresty/luajit \
    --lua-suffix=jit-2.1.0-beta2 \
    --with-lua-include=/usr/local/openresty/luajit/include/luajit-2.1 \
    "

# These are not intended to be user-specified
ARG _RESTY_CONFIG_DEPS="--with-openssl=/tmp/openssl-${RESTY_OPENSSL_VERSION} --with-pcre=/tmp/pcre-${RESTY_PCRE_VERSION}"


#--------------------------------------------------------------------------
# Install Packages
#--------------------------------------------------------------------------

WORKDIR /tmp

# OS libs
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    libgd-dev \
    libgeoip-dev \
    libncurses5-dev \
    libperl-dev \
    libreadline-dev \
    libxslt1-dev \
    libssl-dev \
    make \
    perl \
    unzip \
    zlib1g-dev

# OpenSSL
RUN curl -fSL https://www.openssl.org/source/openssl-${RESTY_OPENSSL_VERSION}.tar.gz -o openssl-${RESTY_OPENSSL_VERSION}.tar.gz \
    && tar xzf openssl-${RESTY_OPENSSL_VERSION}.tar.gz

# PCRE
RUN curl -fSL https://ftp.pcre.org/pub/pcre/pcre-${RESTY_PCRE_VERSION}.tar.gz -o pcre-${RESTY_PCRE_VERSION}.tar.gz \
    && tar xzf pcre-${RESTY_PCRE_VERSION}.tar.gz

# OpenResty
RUN curl -fSL https://openresty.org/download/openresty-${RESTY_VERSION}.tar.gz -o openresty-${RESTY_VERSION}.tar.gz \
    && tar xzf openresty-${RESTY_VERSION}.tar.gz

RUN cd /tmp/openresty-${RESTY_VERSION} \
    && ./configure -j${RESTY_J} ${_RESTY_CONFIG_DEPS} ${RESTY_CONFIG_OPTIONS} \
    && make -j${RESTY_J} \
    && make -j${RESTY_J} install

# LuaRocks
RUN pwd && curl -fSL http://luarocks.org/releases/luarocks-${RESTY_LUAROCKS_VERSION}.tar.gz -o luarocks-${RESTY_LUAROCKS_VERSION}.tar.gz \
    && tar xzf luarocks-${RESTY_LUAROCKS_VERSION}.tar.gz

RUN cd /tmp/luarocks-${RESTY_LUAROCKS_VERSION} \
    && ./configure ${LUAROCKS_CONFIG_OPTIONS} \
    && make build \
    && make install


#--------------------------------------------------------------------------
# Configure Services
#--------------------------------------------------------------------------

# Add additional binaries into PATH for convenience
ENV PATH=$PATH:/usr/local/openresty/luajit/bin/:/usr/local/openresty/nginx/sbin/:/usr/local/openresty/bin/

# Redirect logs to STDOUT/STDIN to be captured by the docker daemon
RUN ln -sf /dev/stdout /usr/local/openresty/nginx/logs/access.log
RUN ln -sf /dev/stderr /usr/local/openresty/nginx/logs/error.log

# Add custom configuration files and lua scripts
ADD nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
ADD ordered_pairs.lua /usr/local/openresty/lualib/resty/ordered_pairs.lua
ADD hmac.lua /usr/local/openresty/lualib/resty/hmac.lua
ADD aws.lua /usr/local/openresty/lualib/resty/aws.lua
ADD elasticsearch-proxy /elasticsearch-proxy


#--------------------------------------------------------------------------
# Clean Up
#--------------------------------------------------------------------------

WORKDIR /tmp
RUN DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
RUN rm -rf luarocks-${RESTY_LUAROCKS_VERSION} luarocks-${RESTY_LUAROCKS_VERSION}.tar.gz
RUN rm -rf openssl-${RESTY_OPENSSL_VERSION} openssl-${RESTY_OPENSSL_VERSION}.tar.gz
RUN rm -rf openresty-${RESTY_VERSION}.tar.gz openresty-${RESTY_VERSION}
RUN rm -rf pcre-${RESTY_PCRE_VERSION}.tar.gz pcre-${RESTY_PCRE_VERSION}
WORKDIR /
