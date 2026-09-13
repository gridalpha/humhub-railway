FROM humhub/humhub:stable

USER root

# Railway-specific boot wrapper. It becomes the image CMD and ends by exec'ing
# the image's own untouched /docker-entrypoint.sh.
COPY files/railway-entrypoint.sh /app/bin/railway-entrypoint.sh
COPY files/railway-db-wait.php /app/bin/railway-db-wait.php
COPY files/railway-normalize-collation.php /app/bin/railway-normalize-collation.php

RUN chmod +x /app/bin/railway-entrypoint.sh \
    && bash -n /app/bin/railway-entrypoint.sh \
    && php -l /app/bin/railway-db-wait.php \
    && php -l /app/bin/railway-normalize-collation.php \
    && test -x /docker-entrypoint.sh \
    && test -x /app/yii

CMD ["/app/bin/railway-entrypoint.sh"]
