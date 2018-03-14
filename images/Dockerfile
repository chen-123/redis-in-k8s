FROM alpine:3.6

# redis docker images
# author caiqyxyx
# date 2017 12 17

# skip installing gem documentation
RUN mkdir -p /usr/local/etc \
	&& { \
		echo 'install: --no-document'; \
		echo 'update: --no-document'; \
	} >> /usr/local/etc/gemrc

RUN apk add --no-cache 'su-exec>=0.2' sed bash ruby

# redis env
ENV REDIS_VERSION 4.0.8
ENV REDIS_DOWNLOAD_URL http://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz
# ENV REDIS_DOWNLOAD_SHA 2049cd6ae9167f258705081a6ef23bb80b7eff9ff3d0d7481e89510f27457591
ENV TIME_ZONE Asiz/Shanghai
# ruby env
ENV RUBY_MAJOR 2.4
ENV RUBY_VERSION 2.4.3
ENV RUBY_DOWNLOAD_SHA256 23677d40bf3b7621ba64593c978df40b1e026d8653c74a0599f0ead78ed92b51
ENV RUBYGEMS_VERSION 2.7.6
ENV BUNDLER_VERSION 1.16.1

# 下载redis 并且编译
RUN set -ex; \
	\
    apk update && apk add --no-cache --virtual .build-deps \
		coreutils \
		gcc \
		linux-headers \
		make \
		musl-dev \
		tzdata \
		tree \
		curl \
		# jq 是用来解析json 的,当然也可以用 grep 和 awk 配合来提取值
		jq \
	; \
	\
	# 设置时区
    cp -r -f /usr/share/zoneinfo/Hongkong /etc/localtime ; \
    echo -ne "Alpine Linux 3.6 image. (`uname -rsv`)\n" >> /root/.built ;\
	wget -O redis.tar.gz "$REDIS_DOWNLOAD_URL"; \
	# echo "$REDIS_DOWNLOAD_SHA *redis.tar.gz" | sha256sum -c -; \
	mkdir -p /usr/src/redis; \
	tar -xzf redis.tar.gz -C /usr/src/redis --strip-components=1; \
	rm redis.tar.gz; \
	\
	grep -q '^#define CONFIG_DEFAULT_PROTECTED_MODE 1$' /usr/src/redis/src/server.h; \
	sed -ri 's!^(#define CONFIG_DEFAULT_PROTECTED_MODE) 1$!\1 0!' /usr/src/redis/src/server.h; \
	grep -q '^#define CONFIG_DEFAULT_PROTECTED_MODE 0$' /usr/src/redis/src/server.h; \
	\
	make -C /usr/src/redis -j "$(nproc)"; \
	make -C /usr/src/redis install; \
	\
	mkdir -p /code/redis ;\
	\
#	mv /usr/src/redis/src/redis-trib.rb /code/redis/redis-trib.rb ;\
	\
	rm -r /usr/src/redis; \
	\
    apk del .build-deps ; \
	apk add --no-cache curl jq 

# some of ruby's build scripts are written in ruby
#   we purge system ruby later to make sure our final image uses what we just built
# readline-dev vs libedit-dev: https://bugs.ruby-lang.org/issues/11869 and https://github.com/docker-library/ruby/issues/75
RUN set -ex \
	\
	&& apk add --no-cache --virtual .ruby-builddeps \
		autoconf \
		bison \
		bzip2 \
		bzip2-dev \
		ca-certificates \
		coreutils \
		dpkg-dev dpkg \
		gcc \
		gdbm-dev \
		glib-dev \
		libc-dev \
		libffi-dev \
		libressl \
		libressl-dev \
		libxml2-dev \
		libxslt-dev \
		linux-headers \
		make \
		ncurses-dev \
		procps \
		readline-dev \
		ruby \
		tar \
		xz \
		yaml-dev \
		zlib-dev \
	\
	&& wget -O ruby.tar.xz "https://cache.ruby-lang.org/pub/ruby/${RUBY_MAJOR%-rc}/ruby-$RUBY_VERSION.tar.xz" \
	&& echo "$RUBY_DOWNLOAD_SHA256 *ruby.tar.xz" | sha256sum -c - \
	\
	&& mkdir -p /usr/src/ruby \
	&& tar -xJf ruby.tar.xz -C /usr/src/ruby --strip-components=1 \
	&& rm ruby.tar.xz \
	\
	&& cd /usr/src/ruby \
	\
# hack in "ENABLE_PATH_CHECK" disabling to suppress:
#   warning: Insecure world writable dir
	&& { \
		echo '#define ENABLE_PATH_CHECK 0'; \
		echo; \
		cat file.c; \
	} > file.c.new \
	&& mv file.c.new file.c \
	\
	&& autoconf \
	&& gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
# the configure script does not detect isnan/isinf as macros
	&& export ac_cv_func_isnan=yes ac_cv_func_isinf=yes \
	&& ./configure \
		--build="$gnuArch" \
		--disable-install-doc \
		--enable-shared \
	&& make -j "$(nproc)" \
	&& make install \
	\
	&& runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)" \
	&& apk add --virtual .ruby-rundeps $runDeps \
		bzip2 \
		ca-certificates \
		libffi-dev \
		libressl-dev \
		procps \
		yaml-dev \
		zlib-dev \
	&& apk del .ruby-builddeps \
	&& cd / \
	&& rm -r /usr/src/ruby \
	\
	&& gem update --system "$RUBYGEMS_VERSION" \
	&& gem install bundler --version "$BUNDLER_VERSION" --force \
	&& rm -r /root/.gem/

ENV GEM_HOME /usr/local/bundle
ENV BUNDLE_PATH="$GEM_HOME" \
	BUNDLE_BIN="$GEM_HOME/bin" \
	BUNDLE_SILENCE_ROOT_WARNING=1 \
	BUNDLE_APP_CONFIG="$GEM_HOME"
ENV PATH $BUNDLE_BIN:$PATH
RUN mkdir -p "$GEM_HOME" "$BUNDLE_BIN" \
	&& chmod 777 "$GEM_HOME" "$BUNDLE_BIN"

EXPOSE 6379
EXPOSE 6380
EXPOSE 26379

COPY redis-master.conf /config/redis/master.conf
COPY redis-slave.conf /config/redis/slave.conf
COPY redis-cluster.conf /config/redis/cluster.conf
RUN touch /config/redis/sentinel.conf
COPY entrypoint.sh /code/redis/entrypoint.sh
COPY redis-4.0.1.gem /redis-4.0.1.gem
COPY rdoc-6.0.0.gem /rdoc-6.0.0.gem
COPY redis-trib.rb /code/redis/redis-trib.rb

RUN chmod +x /code/redis/entrypoint.sh ;\
	chmod +x /code/redis/redis-trib.rb ;\
	cp /code/redis/redis-trib.rb /usr/bin/redis-trib.rb ;\
	chmod +x /usr/bin/redis-trib.rb ;\
	gem install --local /rdoc-6.0.0.gem ;\
	gem install --local /redis-4.0.1.gem

CMD [ "/code/redis/entrypoint.sh" ]
ENTRYPOINT [ "bash", "-c" ]
