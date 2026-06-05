FROM php:7.4-apache

# Debian 旧版(buster/stretch/jessie)已 EOL、官方源下线；仅当检测到时才改用 archive.debian.org
RUN if grep -qsE 'buster|stretch|jessie' /etc/apt/sources.list; then \
        sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g; s|security.debian.org/debian-security|archive.debian.org/debian-security|g; /-updates/d' /etc/apt/sources.list \
        && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99no-check-valid-until; \
    fi

COPY . /var/www/html/

EXPOSE 80

RUN apt-get update -y

RUN apt-get install -y curl

ARG FLAG
RUN sed -i "s/<FLAG>/$FLAG/" /var/www/html/index.php
