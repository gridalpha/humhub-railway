<?php

/**
 * Opens one PDO connection with the same credentials HumHub uses.
 * Exit 0 when the database is reachable, 1 otherwise.
 *
 * Railway has no service start ordering, so the entrypoint polls this before
 * running any migration.
 */

$dsn = getenv('HUMHUB_CONFIG__COMPONENTS__DB__DSN');
$user = getenv('HUMHUB_CONFIG__COMPONENTS__DB__USERNAME');
$pass = getenv('HUMHUB_CONFIG__COMPONENTS__DB__PASSWORD');

if (!$dsn) {
    fwrite(STDERR, "HUMHUB_CONFIG__COMPONENTS__DB__DSN is not set\n");
    exit(1);
}

try {
    $pdo = new PDO($dsn, $user ?: null, $pass ?: null, [
        PDO::ATTR_TIMEOUT => 5,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
    $pdo->query('SELECT 1');
    exit(0);
} catch (Throwable $e) {
    fwrite(STDERR, 'database not ready: ' . $e->getMessage() . "\n");
    exit(1);
}
