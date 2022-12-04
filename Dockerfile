FROM postgres:alpine as builder

FROM alpine:3
LABEL maintainer="d@d.ru"
LABEL maintainer="daniel.sanchez@aranova.es"
LABEL maintainer="pablo.sanchez@aranova.es"  

LABEL org.opencontainers.image.source https://github.com/ARANOVA/docker-alpine-cron

ARG PG_VERSION=15

RUN apk add --no-cache dcron curl ca-certificates mysql-client mariadb-connector-c mongodb-tools redis bash py-pip dos2unix && pip install awscli jq
RUN apk add --no-cache krb5-libs libldap keyutils-libs libsasl
RUN wget https://dl.influxdata.com/influxdb/releases/influxdb-1.8.10-static_linux_amd64.tar.gz && \
  mkdir -p /influxdb && tar xvfz influxdb-1.8.10-static_linux_amd64.tar.gz -C /influxdb && mv /influxdb/influxdb-1.8.10-1/* /influxdb/ && rm -r /influxdb/usr && rm -r /influxdb/influxdb-1.8.10-1 && rm influxdb-1.8.10-static_linux_amd64.tar.gz
RUN mkdir -p /var/log/cron && mkdir -m 0644 -p /var/spool/cron/crontabs && touch /var/log/cron/cron.log && mkdir -m 0644 -p /etc/cron.d
RUN apk add --no-cache tzdata && cp /usr/share/zoneinfo/Europe/Madrid /etc/localtime && apk del tzdata

COPY /scripts/ /
COPY --from=builder /usr/local/bin/pg_dumpall /usr/local/bin/
COPY --from=builder /usr/local/bin/pg_dump /usr/local/bin/
COPY --from=builder /usr/local/lib/libpq* /usr/local/lib/

RUN dos2unix /mysql/* && dos2unix /mongo/* && dos2unix /portainer/* && dos2unix /redis/* && dos2unix /influxdb/* && dos2unix /aws/* && dos2unix /*.sh && chmod a+x /*.sh && chmod a+x /mysql/*.sh && chmod a+x /mongo/*.sh && chmod a+x /portainer/*.sh && chmod a+x /redis/*.sh && chmod a+x /influxdb/*.sh && chmod a+x /aws/*.sh

ENTRYPOINT ["/docker-entry.sh"]
#CMD ["/docker-cmd.sh"]
CMD ["bash", "-c", "sleep 10000"]
