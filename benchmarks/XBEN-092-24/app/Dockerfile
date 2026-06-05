FROM php:8.0-apache

# Debian 旧版(buster/stretch/jessie)已 EOL、官方源下线；仅当检测到时才改用 archive.debian.org
RUN if grep -qsE 'buster|stretch|jessie' /etc/apt/sources.list; then \
        sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g; s|security.debian.org/debian-security|archive.debian.org/debian-security|g; /-updates/d' /etc/apt/sources.list \
        && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99no-check-valid-until; \
    fi

WORKDIR /var/www/html

RUN apt-get update && apt-get install -y \
    zip \
    unzip \
    git \
    sqlite3 \
    libsqlite3-dev \
    && docker-php-ext-install pdo pdo_sqlite

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

COPY . /var/www/html
COPY composer.json /var/www/html/composer.json

COPY wwwconf/ports.conf /etc/apache2/ports.conf
COPY wwwconf/000-default.conf /etc/apache2/sites-available/000-default.conf

RUN groupadd -g 1000 appuser && \
    useradd -u 1000 -g appuser -m appuser

RUN chown -R appuser:appuser /var/www/html

    RUN mkdir -p /var/db && \
    chown -R www-data:www-data /var/db

USER appuser
RUN composer install 

USER root
RUN chown -R www-data:www-data /var/www/html/vendor

EXPOSE 8081

CMD ["apache2-foreground"]
