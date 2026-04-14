<?php
defined('BASEPATH') OR exit('No direct script access allowed');

/**
 * CodeIgniter 3 Config Override for Docker
 * This file is mounted via docker-compose.override.yml
 */

// Base URL (from environment or default)
$config['base_url'] = getenv('APP_BASE_URL') ?: 'http://localhost:8000/';

// Index file (usually index.php or empty for clean URLs)
$config['index_page'] = '';

// URI Protocol
$config['uri_protocol'] = 'REQUEST_URI';

// Subclass prefix (required for CI3)
$config['subclass_prefix'] = 'MY_';

// Session configuration
$config['sess_driver'] = 'files';
$config['sess_cookie_name'] = 'ci_session';
$config['sess_expiration'] = 7200;
$config['sess_save_path'] = getenv('CI3_SESSION_SAVE_PATH') ?: '/tmp/ci_sessions';
$config['sess_match_ip'] = FALSE;
$config['sess_time_to_update'] = 300;
$config['sess_regenerate_destroy'] = FALSE;

// Cookie configuration
$config['cookie_prefix']   = '';
$config['cookie_domain']   = '';
$config['cookie_path']     = '/';
$config['cookie_secure']   = FALSE;
$config['cookie_httponly'] = TRUE;

// CSRF protection (recommended for production)
$config['csrf_protection'] = FALSE;
$config['csrf_token_name'] = 'csrf_token';
$config['csrf_cookie_name'] = 'csrf_cookie';
$config['csrf_expire'] = 7200;
$config['csrf_regenerate'] = TRUE;
$config['csrf_exclude_uris'] = array();

// Character set
$config['charset'] = 'UTF-8';

// Enable profiler (useful for debugging in development)
$config['enable_profiler'] = FALSE;

// Logging
$config['log_threshold'] = 1; // 0=off, 1=error, 2=debug, 3=info, 4=all
$config['log_path'] = '/tmp/ci_logs/'; // Writable directory
$config['log_file_extension'] = '';
$config['log_file_permissions'] = 0666;
$config['log_date_format'] = 'Y-m-d H:i:s';

// Encryption key (override with instance-specific value)
$config['encryption_key'] = getenv('CI3_ENCRYPTION_KEY') ?: '';

// Proxy settings
$config['proxy_ips'] = '';

// Composer autoload
$config['composer_autoload'] = FALSE;
