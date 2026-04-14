<?php
defined('BASEPATH') OR exit('No direct script access allowed');

/**
 * CodeIgniter 3 API Database Config Override for Docker
 * This file is mounted via docker-compose.override.yml for the /api directory
 */

$active_group = 'default';
$query_builder = TRUE;

$db['default'] = array(
    'dsn'      => '',
    'hostname' => getenv('DB_HOST') ?: 'host.docker.internal',
    'port'     => getenv('DB_PORT') ?: '23306',
    'username' => getenv('DB_USER') ?: 'root',
    'password' => getenv('DB_PASSWORD') ?: 'root',
    'database' => getenv('DB_DATABASE') ?: '',
    'dbdriver' => 'mysqli',
    'dbprefix' => '',
    'pconnect' => FALSE,
    'db_debug' => (ENVIRONMENT !== 'production'),
    'cache_on' => FALSE,
    'cachedir' => '',
    'char_set' => 'utf8mb4',
    'dbcollat' => 'utf8mb4_unicode_ci',
    'swap_pre' => '',
    'encrypt'  => FALSE,
    'compress' => FALSE,
    'stricton' => FALSE,
    'failover' => array(),
    'save_queries' => TRUE
);
