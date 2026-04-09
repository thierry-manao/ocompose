<?php
$project = getenv('PROJECT_NAME') ?: 'ocompose';
$dbEngine = getenv('DB_ENGINE') ?: 'mysql';

echo "<h1>🐳 $project is running!</h1>";
echo "<p><strong>PHP Version:</strong> " . phpversion() . "</p>";
echo "<p><strong>Server Time:</strong> " . date('Y-m-d H:i:s') . "</p>";

$host = getenv('DB_HOST') ?: getenv('MYSQL_HOST') ?: $dbEngine;
$user = getenv('DB_USER') ?: getenv('MYSQL_USER') ?: 'app';
$pass = getenv('DB_PASSWORD') ?: getenv('MYSQL_PASSWORD') ?: 'secret';
$db   = getenv('DB_DATABASE') ?: getenv('MYSQL_DATABASE') ?: 'app_db';

echo "<h2>Database Connection ($dbEngine)</h2>";
if ($dbEngine === 'none') {
    echo "<p style='color:#6b7280;'>Database is disabled for this instance.</p>";
} else {
    try {
        if ($dbEngine === 'postgres') {
            $pdo = new PDO("pgsql:host=$host;dbname=$db", $user, $pass);
        } else {
            $pdo = new PDO("mysql:host=$host;dbname=$db", $user, $pass);
        }
        echo "<p style='color:green;'>✅ Connected to $dbEngine ($host / $db)</p>";
    } catch (PDOException $e) {
        echo "<p style='color:red;'>❌ " . htmlspecialchars($e->getMessage(), ENT_QUOTES, 'UTF-8') . "</p>";
    }
}

?>