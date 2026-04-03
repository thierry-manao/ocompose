<?php
$project = getenv('PROJECT_NAME') ?: 'ocompose';
$mysqlEnabled = filter_var(getenv('MYSQL_ENABLED') ?: 'true', FILTER_VALIDATE_BOOLEAN);
$phpMyAdminEnabled = filter_var(getenv('PHPMYADMIN_ENABLED') ?: 'true', FILTER_VALIDATE_BOOLEAN);
$phpMyAdminPort = getenv('PHPMYADMIN_PORT') ?: '8080';

echo "<h1>🐳 $project is running!</h1>";
echo "<p><strong>PHP Version:</strong> " . phpversion() . "</p>";
echo "<p><strong>Server Time:</strong> " . date('Y-m-d H:i:s') . "</p>";

$host = getenv('MYSQL_HOST') ?: 'mysql';
$user = getenv('MYSQL_USER') ?: 'app';
$pass = getenv('MYSQL_PASSWORD') ?: 'secret';
$db   = getenv('MYSQL_DATABASE') ?: 'app_db';

echo "<h2>MySQL Connection</h2>";
if (!$mysqlEnabled) {
    echo "<p style='color:#6b7280;'>MySQL is disabled for this instance.</p>";
} else {
    try {
        $pdo = new PDO("mysql:host=$host;dbname=$db", $user, $pass);
        echo "<p style='color:green;'>✅ Connected to MySQL ($host / $db)</p>";
    } catch (PDOException $e) {
        echo "<p style='color:red;'>❌ " . htmlspecialchars($e->getMessage(), ENT_QUOTES, 'UTF-8') . "</p>";
    }
}

if ($phpMyAdminEnabled) {
    $escapedPort = htmlspecialchars($phpMyAdminPort, ENT_QUOTES, 'UTF-8');
    echo "<hr><p><a id='phpmyadmin-link' data-port='" . $escapedPort . "' href='#'>Open phpMyAdmin →</a></p>";
    echo <<<'HTML'
<script>
(() => {
    const link = document.getElementById('phpmyadmin-link');
    if (!link) {
        return;
    }

    const port = link.dataset.port;
    const hostname = window.location.hostname || 'localhost';
    link.href = `http://${hostname}:${port}`;
})();
</script>
HTML;
} else {
    echo "<hr><p style='color:#6b7280;'>phpMyAdmin is disabled for this instance.</p>";
}
?>