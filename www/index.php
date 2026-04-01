<?php
$project = getenv('PROJECT_NAME') ?: 'ocompose';
echo "<h1>🐳 $project is running!</h1>";
echo "<p><strong>PHP Version:</strong> " . phpversion() . "</p>";
echo "<p><strong>Server Time:</strong> " . date('Y-m-d H:i:s') . "</p>";

$host = getenv('MYSQL_HOST') ?: 'mysql';
$user = getenv('MYSQL_USER') ?: 'app';
$pass = getenv('MYSQL_PASSWORD') ?: 'secret';
$db   = getenv('MYSQL_DATABASE') ?: 'app_db';

echo "<h2>MySQL Connection</h2>";
try {
    $pdo = new PDO("mysql:host=$host;dbname=$db", $user, $pass);
    echo "<p style='color:green;'>✅ Connected to MySQL ($host / $db)</p>";
} catch (PDOException $e) {
    echo "<p style='color:red;'>❌ " . $e->getMessage() . "</p>";
}

echo "<hr><p><a href='http://localhost:8080'>Open phpMyAdmin →</a></p>";
?>