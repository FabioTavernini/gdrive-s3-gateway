FROM rclone/rclone:1.68.2

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV RCLONE_CONFIG=/config/rclone/rclone.conf \
    RCLONE_REMOTE=drive: \
    RCLONE_S3_ADDR=:8080

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
