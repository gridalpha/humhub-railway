<?php

/**
 * Aligns every HumHub table with the database's own default collation.
 *
 * On MySQL 8/9 a `CREATE TABLE ... CHARACTER SET utf8mb4` with no COLLATE gets
 * the *charset's* default (utf8mb4_0900_ai_ci) rather than the database's
 * (utf8mb4_unicode_ci on Railway's managed MySQL), so a handful of HumHub
 * tables end up on a different collation from the rest. HumHub's own
 * prerequisite check reports it, and a join across the split can fail with
 * "Illegal mix of collations".
 *
 * Idempotent: it only touches tables that actually deviate, so it is a single
 * information_schema query on every boot after the first.
 */

$dsn = getenv('HUMHUB_CONFIG__COMPONENTS__DB__DSN');
$user = getenv('HUMHUB_CONFIG__COMPONENTS__DB__USERNAME');
$pass = getenv('HUMHUB_CONFIG__COMPONENTS__DB__PASSWORD');

if (!$dsn) {
    exit(0);
}

try {
    $pdo = new PDO($dsn, $user ?: null, $pass ?: null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);

    $target = $pdo->query(
        'SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = DATABASE()',
    )->fetchColumn();

    if (!is_string($target) || !str_starts_with($target, 'utf8mb4')) {
        fwrite(STDERR, "[collation] database default is '$target', leaving tables alone\n");
        exit(0);
    }

    $stmt = $pdo->prepare(
        'SELECT TABLE_NAME FROM information_schema.TABLES
          WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = "BASE TABLE" AND TABLE_COLLATION <> ?',
    );
    $stmt->execute([$target]);
    $tables = $stmt->fetchAll(PDO::FETCH_COLUMN);

    if (!$tables) {
        exit(0);
    }

    $charset = explode('_', $target)[0];
    foreach ($tables as $table) {
        $pdo->exec(sprintf(
            'ALTER TABLE `%s` CONVERT TO CHARACTER SET %s COLLATE %s',
            str_replace('`', '', $table),
            $charset,
            $target,
        ));
        echo "[collation] $table -> $target\n";
    }
} catch (Throwable $e) {
    // Never block the boot over a cosmetic collation difference.
    fwrite(STDERR, '[collation] skipped: ' . $e->getMessage() . "\n");
}
