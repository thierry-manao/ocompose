<?php
defined('BASEPATH') OR exit('No direct script access allowed');

/**
 * CodeIgniter 3 API Config Override for Docker
 * This file is mounted via docker-compose.override.yml for the /api directory
 */

// API Base URL
$config['base_url'] = getenv('APP_BASE_URL')
    ? rtrim(getenv('APP_BASE_URL'), '/') . '/api/'
    : 'http://localhost:8001/';

// Index file
$config['index_page'] = '';

// URI Protocol
$config['uri_protocol'] = 'REQUEST_URI';

// Subclass prefix (required for CI3)
$config['subclass_prefix'] = 'MY_';

// Session configuration
$config['sess_driver'] = 'files';
$config['sess_cookie_name'] = 'ci_session_api';
$config['sess_expiration'] = 7200;
$config['sess_save_path'] = getenv('CI3_SESSION_SAVE_PATH') ?: '/tmp/ci_sessions';
$config['sess_match_ip'] = FALSE;
$config['sess_time_to_update'] = 300;
$config['sess_regenerate_destroy'] = FALSE;

// Cookie configuration
$config['cookie_prefix']   = '';
$config['cookie_domain']   = '';
$config['cookie_path']     = '/api/';
$config['cookie_secure']   = FALSE;
$config['cookie_httponly'] = TRUE;

// CSRF protection
$config['csrf_protection'] = FALSE;
$config['csrf_token_name'] = 'csrf_token';
$config['csrf_cookie_name'] = 'csrf_cookie';
$config['csrf_expire'] = 7200;
$config['csrf_regenerate'] = TRUE;
$config['csrf_exclude_uris'] = array();

// Character set
$config['charset'] = 'UTF-8';

// Enable profiler
$config['enable_profiler'] = FALSE;

// Logging
$config['log_threshold'] = 1;
$config['log_path'] = '/tmp/ci_logs/'; // Writable directory
$config['log_file_extension'] = '';
$config['log_file_permissions'] = 0666;
$config['log_date_format'] = 'Y-m-d H:i:s';

// Encryption key
$config['encryption_key'] = getenv('CI3_ENCRYPTION_KEY') ?: '';

// Proxy settings
$config['proxy_ips'] = '';

// Composer autoload
$config['composer_autoload'] = FALSE;
