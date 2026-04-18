#!/usr/bin/env python3
"""
WebStack Manager GUI
A PySide6-based GUI for managing the portable web development stack
"""

import sys
import os
import subprocess
import signal
import shutil
import threading
from pathlib import Path
from datetime import datetime

from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, 
                               QHBoxLayout, QPushButton, QTextEdit, QLabel, 
                               QTabWidget, QGroupBox, QProgressBar, QMessageBox,
                               QSystemTrayIcon, QMenu, QCheckBox, QSpinBox,
                               QComboBox, QFormLayout, QSplitter, QFrame,
                               QStyle, QListWidget, QListWidgetItem)
from PySide6.QtCore import QProcess, QTimer, Qt, QSettings
from PySide6.QtGui import QIcon, QAction, QFont, QPalette, QColor, QPixmap, QPainter, QTextCursor

PHP_ICU_TEST_SCRIPT = """<?php
if (extension_loaded('intl')) {
    echo "✓ intl extension loaded\\n";
    echo "✓ ICU version: " . INTL_ICU_VERSION . "\\n";
    echo "✓ ICU data version: " . INTL_ICU_DATA_VERSION . "\\n";

    $coll = collator_create('en_US');
    if ($coll) {
        echo "✓ Collator created successfully\\n";
    } else {
        echo "❌ Collator creation failed\\n";
    }
} else {
    echo "❌ intl extension not loaded\\n";
}
?>"""

# ── New installer layout ──────────────────────────────────────────────────────
#   Binaries / shared:  /opt/webstack          (INSTALL_DIR)
#   Per-user runtime:   ~/.webstack/            (USER_DIR)
#   Web root:           ~/webstack-www/         (USER_WWW)
# ─────────────────────────────────────────────────────────────────────────────

def get_install_dir():
    """Return the shared binary directory (/opt/webstack or override)."""
    if 'WEBSTACK_HOME' in os.environ:
        return os.environ['WEBSTACK_HOME']
    for path in ["/opt/webstack", os.path.expanduser("~/webstack")]:
        if os.path.exists(path):
            return path
    return "/opt/webstack"

def load_paths_file(install_dir):
    """Parse ~/.webstack/.paths written by the installer."""
    paths = {
        "INSTALL_DIR": install_dir,
        "USER_DIR": os.path.expanduser("~/.webstack"),
        "USER_WWW": os.path.expanduser("~/webstack-www"),
    }
    paths_file = os.path.join(paths["USER_DIR"], ".paths")
    if os.path.exists(paths_file):
        with open(paths_file) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    paths[k.strip()] = v.strip().strip('"')
    return paths


class WebStackManager(QMainWindow):
    def __init__(self):
        super().__init__()
        # ── Paths (new split layout) ──────────────────────────────────────
        install_dir = get_install_dir()
        _p = load_paths_file(install_dir)
        self.stack_dir  = _p["INSTALL_DIR"]   # /opt/webstack  (binaries)
        self.user_dir   = _p["USER_DIR"]       # ~/.webstack    (runtime data)
        self.user_www   = _p["USER_WWW"]       # ~/webstack-www (web root)
        self.deps_dir   = os.path.join(self.stack_dir, "deps")
        # ── Legacy alias so old helper methods still work ─────────────────
        # (methods that previously used self.stack_dir for runtime files
        #  have been updated to use self.user_dir instead)
        self.processes  = {}
        self.settings   = QSettings("WebStack", "Manager")
        self.init_ui()
        self.load_settings()
        
    def init_ui(self):
        """Initialize the user interface"""
        self.setWindowTitle("WebStack Manager")
        self.setMinimumSize(900, 700)
        
        # Create central widget and main layout
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)
        
        # Create tab widget
        tabs = QTabWidget()
        layout.addWidget(tabs)
        
        # Status tab
        status_tab = self.create_status_tab()
        tabs.addTab(status_tab, "Status")
        
        # Control tab
        control_tab = self.create_control_tab()
        tabs.addTab(control_tab, "Control")
        
        # Diagnostics tab
        diag_tab = self.create_diagnostics_tab()
        tabs.addTab(diag_tab, "Diagnostics")
        
        # Settings tab
        settings_tab = self.create_settings_tab()
        tabs.addTab(settings_tab, "Settings")
        
        # Log viewer
        log_tab = self.create_log_tab()
        tabs.addTab(log_tab, "Logs")
        
        # Create system tray icon
        self.create_tray_icon()
        
        # Start monitoring
        self.monitor_timer = QTimer()
        self.monitor_timer.timeout.connect(self.update_status)
        self.monitor_timer.start(2000)  # Update every 2 seconds
        
    def get_environment(self):
        """Get the proper environment for webstack services"""
        env = os.environ.copy()

        lib_paths = [
            os.path.join(self.deps_dir, "lib"),
            os.path.join(self.deps_dir, "lib64"),
            os.path.join(self.stack_dir, "postgresql", "lib"),
        ]
        existing_lib_paths = [p for p in lib_paths if os.path.exists(p)]
        if existing_lib_paths:
            env['LD_LIBRARY_PATH'] = ":".join(existing_lib_paths)

        bin_paths = [
            os.path.join(self.deps_dir, "bin"),
            os.path.join(self.stack_dir, "bin"),
            os.path.join(self.user_dir, "bin"),
        ]
        existing_bin_paths = [p for p in bin_paths if os.path.exists(p)]
        if existing_bin_paths:
            env['PATH'] = ":".join(existing_bin_paths) + ":" + env.get('PATH', '')

        env['WEBSTACK_HOME'] = self.stack_dir
        return env
        
    def get_fallback_environment(self):
        """Fallback environment setup if env.sh is not available"""
        env = os.environ.copy()
        
        # Add library paths
        lib_paths = [
            os.path.join(self.deps_dir, "lib"),
            os.path.join(self.deps_dir, "lib64"),
            "/usr/lib",
            "/usr/lib64",
            "/lib",
            "/lib64"
        ]
        
        # Filter out non-existent paths and join them
        existing_lib_paths = [p for p in lib_paths if os.path.exists(p)]
        ld_library_path = ":".join(existing_lib_paths)
        
        # Add to existing LD_LIBRARY_PATH if it exists
        if 'LD_LIBRARY_PATH' in env:
            env['LD_LIBRARY_PATH'] = ld_library_path + ":" + env['LD_LIBRARY_PATH']
        else:
            env['LD_LIBRARY_PATH'] = ld_library_path
            
        # Add binary paths
        bin_paths = [
            os.path.join(self.deps_dir, "bin"),
            os.path.join(self.stack_dir, "bin"),
            "/usr/bin",
            "/bin"
        ]
        
        existing_bin_paths = [p for p in bin_paths if os.path.exists(p)]
        path = ":".join(existing_bin_paths)
        
        if 'PATH' in env:
            env['PATH'] = path + ":" + env['PATH']
        else:
            env['PATH'] = path
            
        # Set other important variables
        env['WEBSTACK_HOME'] = self.stack_dir
        env['PKG_CONFIG_PATH'] = os.path.join(self.deps_dir, "lib", "pkgconfig")
            
        return env
        
    def create_status_tab(self):
        """Create the status monitoring tab"""
        widget = QWidget()
        layout = QVBoxLayout(widget)
        
        # Status indicators
        status_group = QGroupBox("Service Status")
        status_layout = QFormLayout(status_group)
        
        self.nginx_status = QLabel("Stopped")
        self.nginx_status.setStyleSheet("color: red; font-weight: bold;")
        status_layout.addRow("Nginx:", self.nginx_status)
        
        self.php_status = QLabel("Stopped")
        self.php_status.setStyleSheet("color: red; font-weight: bold;")
        status_layout.addRow("PHP-FPM:", self.php_status)
        
        self.mysql_status = QLabel("Stopped")
        self.mysql_status.setStyleSheet("color: red; font-weight: bold;")
        status_layout.addRow("MariaDB:", self.mysql_status)
        
        self.pgsql_status = QLabel("Stopped")
        self.pgsql_status.setStyleSheet("color: red; font-weight: bold;")
        status_layout.addRow("PostgreSQL:", self.pgsql_status)
        
        layout.addWidget(status_group)
        
        # Quick actions
        actions_group = QGroupBox("Quick Actions")
        actions_layout = QHBoxLayout(actions_group)
        
        self.start_btn = QPushButton("Start All")
        self.start_btn.clicked.connect(self.start_all_services)
        actions_layout.addWidget(self.start_btn)
        
        self.stop_btn = QPushButton("Stop All")
        self.stop_btn.clicked.connect(self.stop_all_services)
        actions_layout.addWidget(self.stop_btn)
        
        self.restart_btn = QPushButton("Restart All")
        self.restart_btn.clicked.connect(self.restart_all_services)
        actions_layout.addWidget(self.restart_btn)
        
        layout.addWidget(actions_group)
        
        # System info
        info_group = QGroupBox("System Information")
        info_layout = QFormLayout(info_group)
        
        self.stack_path = QLabel(self.stack_dir)
        info_layout.addRow("Binaries (INSTALL_DIR):", self.stack_path)

        self.user_dir_label = QLabel(self.user_dir)
        info_layout.addRow("Runtime data (USER_DIR):", self.user_dir_label)

        self.user_www_label = QLabel(self.user_www)
        info_layout.addRow("Web root (USER_WWW):", self.user_www_label)

        self.web_url = QLabel("http://localhost:8080")
        info_layout.addRow("Web URL:", self.web_url)
        
        self.php_version = QLabel("Unknown")
        info_layout.addRow("PHP Version:", self.php_version)
        
        self.stack_health = QLabel("Checking...")
        info_layout.addRow("Stack Health:", self.stack_health)
        
        layout.addWidget(info_group)
        
        layout.addStretch()
        
        return widget
        
    def create_control_tab(self):
        """Create the service control tab"""
        widget = QWidget()
        layout = QVBoxLayout(widget)
        
        # Nginx control
        nginx_group = QGroupBox("Nginx Control")
        nginx_layout = QHBoxLayout(nginx_group)
        
        self.nginx_start_btn = QPushButton("Start")
        self.nginx_start_btn.clicked.connect(lambda: self.start_service("nginx"))
        nginx_layout.addWidget(self.nginx_start_btn)
        
        self.nginx_stop_btn = QPushButton("Stop")
        self.nginx_stop_btn.clicked.connect(lambda: self.stop_service("nginx"))
        nginx_layout.addWidget(self.nginx_stop_btn)
        
        self.nginx_restart_btn = QPushButton("Restart")
        self.nginx_restart_btn.clicked.connect(lambda: self.restart_service("nginx"))
        nginx_layout.addWidget(self.nginx_restart_btn)
        
        nginx_layout.addStretch()
        
        self.nginx_test_btn = QPushButton("Test Config")
        self.nginx_test_btn.clicked.connect(self.test_nginx_config)
        nginx_layout.addWidget(self.nginx_test_btn)
        
        layout.addWidget(nginx_group)
        
        # PHP-FPM control
        php_group = QGroupBox("PHP-FPM Control")
        php_layout = QHBoxLayout(php_group)
        
        self.php_start_btn = QPushButton("Start")
        self.php_start_btn.clicked.connect(lambda: self.start_service("php"))
        php_layout.addWidget(self.php_start_btn)
        
        self.php_stop_btn = QPushButton("Stop")
        self.php_stop_btn.clicked.connect(lambda: self.stop_service("php"))
        php_layout.addWidget(self.php_stop_btn)
        
        self.php_restart_btn = QPushButton("Restart")
        self.php_restart_btn.clicked.connect(lambda: self.restart_service("php"))
        php_layout.addWidget(self.php_restart_btn)
        
        # PHP version selector
        php_layout.addWidget(QLabel("Version:"))
        self.php_version_combo = QComboBox()
        self.php_version_combo.currentTextChanged.connect(self.switch_php_version)
        php_layout.addWidget(self.php_version_combo)
        
        php_layout.addStretch()
        
        self.php_test_btn = QPushButton("Test PHP")
        self.php_test_btn.clicked.connect(self.test_php)
        php_layout.addWidget(self.php_test_btn)
        
        layout.addWidget(php_group)
        
        # MariaDB control
        mysql_group = QGroupBox("MariaDB Control")
        mysql_layout = QHBoxLayout(mysql_group)
        
        self.mysql_start_btn = QPushButton("Start")
        self.mysql_start_btn.clicked.connect(lambda: self.start_service("mysql"))
        mysql_layout.addWidget(self.mysql_start_btn)
        
        self.mysql_stop_btn = QPushButton("Stop")
        self.mysql_stop_btn.clicked.connect(lambda: self.stop_service("mysql"))
        mysql_layout.addWidget(self.mysql_stop_btn)
        
        self.mysql_restart_btn = QPushButton("Restart")
        self.mysql_restart_btn.clicked.connect(lambda: self.restart_service("mysql"))
        mysql_layout.addWidget(self.mysql_restart_btn)
        
        mysql_layout.addStretch()
        
        self.mysql_test_btn = QPushButton("Test MySQL")
        self.mysql_test_btn.clicked.connect(self.test_mysql)
        mysql_layout.addWidget(self.mysql_test_btn)
        
        layout.addWidget(mysql_group)
        
        # PostgreSQL control
        pgsql_group = QGroupBox("PostgreSQL Control")
        pgsql_layout = QHBoxLayout(pgsql_group)
        
        self.pgsql_start_btn = QPushButton("Start")
        self.pgsql_start_btn.clicked.connect(lambda: self.start_service("postgresql"))
        pgsql_layout.addWidget(self.pgsql_start_btn)
        
        self.pgsql_stop_btn = QPushButton("Stop")
        self.pgsql_stop_btn.clicked.connect(lambda: self.stop_service("postgresql"))
        pgsql_layout.addWidget(self.pgsql_stop_btn)
        
        self.pgsql_restart_btn = QPushButton("Restart")
        self.pgsql_restart_btn.clicked.connect(lambda: self.restart_service("postgresql"))
        pgsql_layout.addWidget(self.pgsql_restart_btn)
        
        pgsql_layout.addStretch()
        
        self.pgsql_test_btn = QPushButton("Test PostgreSQL")
        self.pgsql_test_btn.clicked.connect(self.test_postgresql)
        pgsql_layout.addWidget(self.pgsql_test_btn)
        
        layout.addWidget(pgsql_group)
        
        # Environment section
        env_group = QGroupBox("Environment Configuration")
        env_layout = QVBoxLayout(env_group)
        
        env_info_layout = QHBoxLayout()
        self.env_status = QLabel("Environment: Not loaded")
        env_info_layout.addWidget(self.env_status)
        
        self.load_env_btn = QPushButton("Load Environment")
        self.load_env_btn.clicked.connect(self.load_environment)
        env_info_layout.addWidget(self.load_env_btn)
        
        self.source_env_btn = QPushButton("Show Paths")
        self.source_env_btn.setToolTip("Display active path configuration from ~/.webstack/.paths")
        self.source_env_btn.clicked.connect(self.source_env_sh)
        env_info_layout.addWidget(self.source_env_btn)
        
        env_layout.addLayout(env_info_layout)
        
        # Library path display
        self.lib_path_display = QTextEdit()
        self.lib_path_display.setMaximumHeight(80)
        self.lib_path_display.setFont(QFont("Monospace", 8))
        self.lib_path_display.setReadOnly(True)
        env_layout.addWidget(QLabel("Library Paths:"))
        env_layout.addWidget(self.lib_path_display)
        
        layout.addWidget(env_group)
        
        # Cleanup section
        cleanup_group = QGroupBox("Cleanup && Maintenance")
        cleanup_layout = QVBoxLayout(cleanup_group)
        
        cleanup_btn_layout = QHBoxLayout()
        
        self.clean_logs_btn = QPushButton("Clean Logs")
        self.clean_logs_btn.clicked.connect(self.clean_logs)
        cleanup_btn_layout.addWidget(self.clean_logs_btn)
        
        self.clean_build_btn = QPushButton("Clean Build Files")
        self.clean_build_btn.clicked.connect(self.clean_build_files)
        cleanup_btn_layout.addWidget(self.clean_build_btn)
        
        self.clean_all_btn = QPushButton("Full Cleanup")
        self.clean_all_btn.clicked.connect(self.full_cleanup)
        cleanup_btn_layout.addWidget(self.clean_all_btn)
        
        self.fix_symlinks_btn = QPushButton("Fix Symlinks")
        self.fix_symlinks_btn.clicked.connect(self.fix_php_symlinks)
        cleanup_btn_layout.addWidget(self.fix_symlinks_btn)
        
        self.fix_mysql_socket_btn = QPushButton("Fix MySQL Socket")
        self.fix_mysql_socket_btn.clicked.connect(self.fix_mysql_socket)
        cleanup_btn_layout.addWidget(self.fix_mysql_socket_btn)
        
        cleanup_layout.addLayout(cleanup_btn_layout)
        
        # Auto-cleanup options
        auto_clean_layout = QHBoxLayout()
        self.auto_clean_logs = QCheckBox("Auto-clean logs on stop")
        auto_clean_layout.addWidget(self.auto_clean_logs)
        
        self.auto_clean_temp = QCheckBox("Auto-clean temp files")
        auto_clean_layout.addWidget(self.auto_clean_temp)
        
        cleanup_layout.addLayout(auto_clean_layout)
        
        layout.addWidget(cleanup_group)
        
        layout.addStretch()
        
        return widget

    def create_diagnostics_tab(self):
        """Create diagnostics tab to troubleshoot issues"""
        widget = QWidget()
        layout = QVBoxLayout(widget)
        
        # Diagnostics controls
        diag_controls = QHBoxLayout()
        
        self.run_diag_btn = QPushButton("Run Diagnostics")
        self.run_diag_btn.clicked.connect(self.run_diagnostics)
        diag_controls.addWidget(self.run_diag_btn)
        
        self.repair_btn = QPushButton("Auto-Repair")
        self.repair_btn.clicked.connect(self.auto_repair)
        diag_controls.addWidget(self.repair_btn)
        
        self.check_libs_btn = QPushButton("Check Libraries")
        self.check_libs_btn.clicked.connect(self.check_libraries)
        diag_controls.addWidget(self.check_libs_btn)
        
        diag_controls.addStretch()
        
        layout.addLayout(diag_controls)
        
        # Diagnostics output
        self.diag_output = QTextEdit()
        self.diag_output.setFont(QFont("Monospace", 9))
        self.diag_output.setReadOnly(True)
        layout.addWidget(self.diag_output)
        
        return widget
        
    def create_settings_tab(self):
        """Create the settings tab"""
        widget = QWidget()
        layout = QVBoxLayout(widget)
        
        # Stack configuration
        config_group = QGroupBox("Stack Configuration")
        config_layout = QFormLayout(config_group)
        
        self.stack_dir_edit = QLabel(self.stack_dir)
        config_layout.addRow("Binaries (INSTALL_DIR):", self.stack_dir_edit)

        self.user_dir_edit = QLabel(self.user_dir)
        config_layout.addRow("Runtime data (USER_DIR):", self.user_dir_edit)
        
        self.nginx_port = QSpinBox()
        self.nginx_port.setRange(1024, 65535)
        self.nginx_port.setValue(8080)
        self.nginx_port.valueChanged.connect(self.on_ports_changed)
        config_layout.addRow("Nginx Port:", self.nginx_port)
        
        self.mysql_port = QSpinBox()
        self.mysql_port.setRange(1024, 65535)
        self.mysql_port.setValue(3306)
        self.mysql_port.valueChanged.connect(self.on_ports_changed)
        config_layout.addRow("MySQL Port:", self.mysql_port)
        
        self.pgsql_port = QSpinBox()
        self.pgsql_port.setRange(1024, 65535)
        self.pgsql_port.setValue(5432)
        self.pgsql_port.valueChanged.connect(self.on_ports_changed)
        config_layout.addRow("PostgreSQL Port:", self.pgsql_port)
        
        # Apply ports button
        self.apply_ports_btn = QPushButton("Apply Port Changes")
        self.apply_ports_btn.clicked.connect(self.apply_port_changes)
        self.apply_ports_btn.setEnabled(False)
        config_layout.addRow("", self.apply_ports_btn)
        
        layout.addWidget(config_group)
        
        # Behavior settings
        behavior_group = QGroupBox("Behavior")
        behavior_layout = QVBoxLayout(behavior_group)
        
        self.start_minimized = QCheckBox("Start minimized to system tray")
        behavior_layout.addWidget(self.start_minimized)
        
        self.auto_start = QCheckBox("Auto-start services on application launch")
        behavior_layout.addWidget(self.auto_start)
        
        self.auto_stop = QCheckBox("Auto-stop services on application exit")
        behavior_layout.addWidget(self.auto_stop)
        
        self.auto_load_env = QCheckBox("Auto-load environment on start")
        self.auto_load_env.setChecked(True)
        behavior_layout.addWidget(self.auto_load_env)
        
        layout.addWidget(behavior_group)
        
        # Save settings
        save_layout = QHBoxLayout()
        self.save_btn = QPushButton("Save Settings")
        self.save_btn.clicked.connect(self.save_settings)
        save_layout.addWidget(self.save_btn)
        
        self.reset_btn = QPushButton("Reset to Defaults")
        self.reset_btn.clicked.connect(self.reset_settings)
        save_layout.addWidget(self.reset_btn)
        
        layout.addLayout(save_layout)
        layout.addStretch()
        
        return widget

    def on_ports_changed(self):
        """Enable apply button when ports are changed"""
        self.apply_ports_btn.setEnabled(True)

    def apply_port_changes(self):
        """Apply port changes to service configurations"""
        try:
            nginx_port = self.nginx_port.value()
            mysql_port = self.mysql_port.value()
            pgsql_port = self.pgsql_port.value()
            
            # Update Nginx configuration
            self.update_nginx_port(nginx_port)
            
            # Update MySQL configuration  
            self.update_mysql_port(mysql_port)
            
            # Update PostgreSQL configuration
            self.update_postgresql_port(pgsql_port)
            
            # Update web URL display
            self.web_url.setText(f"http://localhost:{nginx_port}")
            
            self.apply_ports_btn.setEnabled(False)
            self.log_message(f"Applied port changes: Nginx={nginx_port}, MySQL={mysql_port}, PostgreSQL={pgsql_port}")
            QMessageBox.information(self, "Port Changes", 
                                f"Port changes applied successfully!\n\n"
                                f"Nginx: {nginx_port}\n"
                                f"MySQL: {mysql_port}\n"
                                f"PostgreSQL: {pgsql_port}\n\n"
                                f"Restart services for changes to take effect.")
                                
        except Exception as e:
            self.log_message(f"Error applying port changes: {e}")
            QMessageBox.critical(self, "Port Changes", f"Failed to apply port changes: {e}")

    def update_nginx_port(self, port):
        """Update Nginx configuration with new port"""
        nginx_conf = Path(self.user_dir) / "nginx" / "nginx.conf"
        
        if not nginx_conf.exists():
            # Create basic nginx configuration if it doesn't exist
            self.create_nginx_config(port)
            return
            
        # Read current configuration
        with open(nginx_conf, 'r') as f:
            content = f.read()
        
        # Update port in listen directive
        import re
        # Replace any existing port in listen directives
        content = re.sub(r'listen\s+\d+;', f'listen {port};', content)
        
        # Write updated configuration
        with open(nginx_conf, 'w') as f:
            f.write(content)
        
        self.log_message(f"Updated Nginx port to {port}")

    def update_mysql_port(self, port):
        """Update MySQL configuration with new port"""
        mysql_cnf = Path(self.user_dir) / "mariadb" / "my.cnf"
        
        if not mysql_cnf.exists():
            # Create basic MySQL configuration if it doesn't exist
            self.fix_mysql_socket()  # This will create the config with proper port
            return
            
        # Read current configuration
        with open(mysql_cnf, 'r') as f:
            content = f.read()
        
        # Update port in [mysqld] and [client] sections
        import re
        # Replace port in [mysqld] section
        content = re.sub(r'port\s*=\s*\d+', f'port = {port}', content)
        # Replace port in [client] section  
        content = re.sub(r'port\s*=\s*\d+', f'port = {port}', content)
        
        # Write updated configuration
        with open(mysql_cnf, 'w') as f:
            f.write(content)
        
        self.log_message(f"Updated MySQL port to {port}")

    def create_nginx_config(self, port=8080):
        """Create Nginx configuration file in user_dir"""
        nginx_conf = Path(self.user_dir) / "nginx" / "nginx.conf"
        nginx_conf.parent.mkdir(parents=True, exist_ok=True)

        config_content = f'''worker_processes auto;
error_log {self.user_dir}/nginx/logs/error.log;
pid {self.user_dir}/nginx/nginx.pid;

events {{
    worker_connections 1024;
}}

http {{
    include       {self.stack_dir}/nginx/conf/mime.types;
    default_type  application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    server {{
        listen {port};
        server_name localhost;
        root {self.user_www};
        index index.php index.html index.htm;

        location / {{
            try_files $uri $uri/ /index.php?$query_string;
        }}

        location ~ \\.php$ {{
            fastcgi_pass unix:{self.user_dir}/php/current/php-fpm.sock;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include {self.stack_dir}/nginx/conf/fastcgi_params;
        }}

        location ~ /\\.ht {{
            deny all;
        }}
    }}
}}
'''
        with open(nginx_conf, 'w') as f:
            f.write(config_content)
        self.log_message(f"Created Nginx configuration with port {port}")
        
    def create_log_tab(self):
        """Create the log viewer tab"""
        widget = QWidget()
        layout = QVBoxLayout(widget)
        
        # Log controls
        log_controls = QHBoxLayout()
        
        self.log_combo = QComboBox()
        self.log_combo.addItems(["nginx", "php", "mysql", "postgresql", "system"])
        self.log_combo.currentTextChanged.connect(self.load_log)
        log_controls.addWidget(QLabel("Log:"))
        log_controls.addWidget(self.log_combo)
        
        self.refresh_log_btn = QPushButton("Refresh")
        self.refresh_log_btn.clicked.connect(self.load_log)
        log_controls.addWidget(self.refresh_log_btn)
        
        self.clear_log_btn = QPushButton("Clear Log")
        self.clear_log_btn.clicked.connect(self.clear_log)
        log_controls.addWidget(self.clear_log_btn)
        
        log_controls.addStretch()
        
        self.auto_refresh = QCheckBox("Auto-refresh")
        self.auto_refresh.toggled.connect(self.toggle_auto_refresh)
        log_controls.addWidget(self.auto_refresh)
        
        layout.addLayout(log_controls)
        
        # Log content
        self.log_view = QTextEdit()
        self.log_view.setFont(QFont("Monospace", 9))
        self.log_view.setReadOnly(True)
        layout.addWidget(self.log_view)
        
        return widget
        
    def create_tray_icon(self):
        """Create system tray icon"""
        self.tray_icon = QSystemTrayIcon(self)
        
        # Create a simple icon programmatically
        pixmap = QPixmap(64, 64)
        pixmap.fill(Qt.transparent)
        
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.Antialiasing)
        
        # Draw a simple web/server icon
        painter.setBrush(QColor(66, 133, 244))  # Blue color
        painter.setPen(Qt.NoPen)
        painter.drawEllipse(8, 8, 48, 48)
        
        painter.setBrush(Qt.white)
        painter.drawEllipse(20, 20, 24, 24)
        
        painter.setBrush(QColor(66, 133, 244))
        painter.drawRect(28, 28, 8, 8)
        
        painter.end()
        
        self.tray_icon.setIcon(QIcon(pixmap))
        
        tray_menu = QMenu()
        
        show_action = QAction("Show", self)
        show_action.triggered.connect(self.show)
        tray_menu.addAction(show_action)
        
        tray_menu.addSeparator()
        
        start_action = QAction("Start All Services", self)
        start_action.triggered.connect(self.start_all_services)
        tray_menu.addAction(start_action)
        
        stop_action = QAction("Stop All Services", self)
        stop_action.triggered.connect(self.stop_all_services)
        tray_menu.addAction(stop_action)
        
        tray_menu.addSeparator()
        
        quit_action = QAction("Quit", self)
        quit_action.triggered.connect(self.quit_application)
        tray_menu.addAction(quit_action)
        
        self.tray_icon.setContextMenu(tray_menu)
        self.tray_icon.activated.connect(self.tray_icon_activated)
        self.tray_icon.show()
        
    def tray_icon_activated(self, reason):
        """Handle tray icon activation"""
        if reason == QSystemTrayIcon.DoubleClick:
            self.show()
            self.raise_()
            self.activateWindow()

    def source_env_sh(self):
        """Display current path configuration (env.sh is not used in the new installer)"""
        env = self.get_environment()
        paths_file = Path(self.user_dir) / ".paths"
        info = []
        if paths_file.exists():
            with open(paths_file) as f:
                info.append("=== ~/.webstack/.paths ===")
                info.append(f.read())
        else:
            info.append("~/.webstack/.paths not found (run installer Phase 2)")
        info.append("=== Active environment ===")
        info.append(f"LD_LIBRARY_PATH:\n{env.get('LD_LIBRARY_PATH', 'Not set')}")
        info.append(f"\nPATH prefix:\n{env.get('PATH', 'Not set').split(':')[0]}")
        self.diag_output.append('\n'.join(info))
        self.lib_path_display.setPlainText(
            f"LD_LIBRARY_PATH:\n{env.get('LD_LIBRARY_PATH', 'Not set')}\n\n"
            f"PATH prefix:\n{env.get('PATH', 'Not set').split(':')[0]}")
        self.env_status.setText("Environment: Loaded")
        self.env_status.setStyleSheet("color: green; font-weight: bold;")

    def load_environment(self):
        """Load and display the webstack environment"""
        env = self.get_environment()
        lib_path = env.get('LD_LIBRARY_PATH', 'Not set')
        path_prefix = env.get('PATH', 'Not set').split(':')[0]
        self.lib_path_display.setPlainText(
            f"INSTALL_DIR: {self.stack_dir}\n"
            f"USER_DIR:    {self.user_dir}\n"
            f"USER_WWW:    {self.user_www}\n\n"
            f"LD_LIBRARY_PATH:\n{lib_path}\n\n"
            f"PATH prefix:\n{path_prefix}")
        self.env_status.setText("Environment: Loaded")
        self.env_status.setStyleSheet("color: green; font-weight: bold;")
        self.log_message("WebStack environment loaded")
        return env

    def check_libraries(self):
        """Check for required libraries"""
        self.diag_output.append("\n=== Library Check ===")
        env = self.get_environment()

        # MariaDB binary
        mariadb_binary = Path(self.stack_dir) / "mariadb" / "bin" / "mariadbd"
        if mariadb_binary.exists():
            result = subprocess.run(["ldd", str(mariadb_binary)],
                                    capture_output=True, text=True, env=env)
            if "not found" in result.stdout:
                self.diag_output.append("❌ MariaDB has missing libraries:")
                for line in result.stdout.split('\n'):
                    if "not found" in line:
                        self.diag_output.append(f"  {line.strip()}")
            else:
                self.diag_output.append("✓ MariaDB libraries OK")
        else:
            self.diag_output.append("❌ MariaDB binary not found")

        # ICU search
        self.diag_output.append("\n=== ICU Library Search ===")
        icu_patterns = ["libicudata*", "libicuuc*", "libicui18n*"]
        found_icu_libs = []
        for pattern in icu_patterns:
            r = subprocess.run(["find", self.deps_dir, "-name", pattern, "-type", "f"],
                               capture_output=True, text=True)
            if r.stdout.strip():
                found_icu_libs.extend(r.stdout.strip().split('\n'))
        if found_icu_libs:
            self.diag_output.append(f"✓ {len(found_icu_libs)} ICU library files found")
            for lib in sorted(found_icu_libs):
                self.diag_output.append(f"  {Path(lib).name}")
        else:
            self.diag_output.append("❌ No ICU libraries found in deps")

        # PHP binary check
        current_link = Path(self.user_dir) / "php" / "current"
        if current_link.is_symlink():
            try:
                ver = current_link.resolve().name
                php_binary = Path(self.stack_dir) / "php" / ver / "bin" / "php"
                if php_binary.exists():
                    self.diag_output.append("\n=== PHP Library Check ===")
                    r = subprocess.run(["ldd", str(php_binary)],
                                       capture_output=True, text=True, env=env)
                    if "not found" in r.stdout:
                        self.diag_output.append("❌ PHP has missing libraries:")
                        for line in r.stdout.split('\n'):
                            if "not found" in line:
                                self.diag_output.append(f"  {line.strip()}")
                    else:
                        self.diag_output.append("✓ PHP libraries OK")
            except Exception:
                pass

        self.diag_output.append("=== Library Check Complete ===")

    def fix_mysql_socket(self):
        """Fix MariaDB socket/config — user_dir holds runtime data, stack_dir is basedir"""
        try:
            mysql_user_dir = Path(self.user_dir)  / "mariadb"
            mysql_base_dir = Path(self.stack_dir) / "mariadb"
            my_cnf         = mysql_user_dir / "my.cnf"

            current_port = 3306
            if hasattr(self, 'mysql_port'):
                current_port = self.mysql_port.value()

            my_cnf_content = f"""[mysqld]
basedir = {mysql_base_dir}
datadir = {mysql_user_dir}/data
port = {current_port}
socket = {mysql_user_dir}/mariadb.sock
pid-file = {mysql_user_dir}/mariadb.pid
log-error = {mysql_user_dir}/logs/error.log
bind-address = 127.0.0.1
skip-name-resolve
innodb_buffer_pool_size = 64M
innodb_log_file_size = 48M

[client]
port = {current_port}
socket = {mysql_user_dir}/mariadb.sock
"""
            for d in [mysql_user_dir / "logs", mysql_user_dir / "data"]:
                d.mkdir(parents=True, exist_ok=True)

            with open(my_cnf, 'w') as f:
                f.write(my_cnf_content)
            os.chmod(my_cnf, 0o600)

            self.log_message("MariaDB configuration fixed")
            QMessageBox.information(self, "Fix MariaDB Config",
                "MariaDB configuration fixed successfully!")
        except Exception as e:
            self.log_message(f"Error fixing MariaDB config: {e}")
            QMessageBox.critical(self, "Fix MariaDB Config",
                f"Failed to fix config: {e}")

    def check_icu_via_php(self):
        """Check ICU functionality via PHP"""
        import tempfile
        try:
            env = self.get_environment()
            current_link = Path(self.user_dir) / "php" / "current"
            if not current_link.is_symlink():
                return "PHP current symlink not found"
            ver = current_link.resolve().name
            php_binary = Path(self.stack_dir) / "php" / ver / "bin" / "php"
            if not php_binary.exists():
                return f"PHP binary not found: {php_binary}"
            with tempfile.NamedTemporaryFile(mode='w', suffix='.php', delete=False) as f:
                f.write(PHP_ICU_TEST_SCRIPT)
                temp_path = f.name
            try:
                result = subprocess.run([str(php_binary), temp_path],
                                        capture_output=True, text=True, env=env)
                return result.stdout
            finally:
                Path(temp_path).unlink(missing_ok=True)
        except Exception as e:
            return f"Error testing ICU: {e}"

    def run_diagnostics(self):
        """Run comprehensive diagnostics"""
        self.diag_output.clear()
        self.diag_output.append("=== WebStack Diagnostics ===\n")

        # ── Directories ──────────────────────────────────────────────────
        self.diag_output.append(f"INSTALL_DIR : {self.stack_dir}")
        self.diag_output.append(f"USER_DIR    : {self.user_dir}")
        self.diag_output.append(f"USER_WWW    : {self.user_www}\n")

        if not Path(self.stack_dir).exists():
            self.diag_output.append("❌ INSTALL_DIR does not exist!")
            return
        self.diag_output.append("✓ INSTALL_DIR exists")

        if Path(self.user_dir).exists():
            self.diag_output.append("✓ USER_DIR exists")
        else:
            self.diag_output.append("❌ USER_DIR missing — run installer Phase 2")

        if Path(self.user_www).exists():
            self.diag_output.append("✓ USER_WWW exists")
        else:
            self.diag_output.append("❌ USER_WWW missing — run installer Phase 2")

        # ── Binaries (stack_dir) ────────────────────────────────────────
        self.diag_output.append("\n=== Binaries (INSTALL_DIR) ===")
        components = {
            "Nginx binary"       : Path(self.stack_dir) / "nginx" / "nginx",
            "nginx/conf/mime.types"    : Path(self.stack_dir) / "nginx" / "conf" / "mime.types",
            "nginx/conf/fastcgi_params": Path(self.stack_dir) / "nginx" / "conf" / "fastcgi_params",
            "MariaDB safe"       : Path(self.stack_dir) / "mariadb" / "bin" / "mariadbd-safe",
            "MariaDB daemon"     : Path(self.stack_dir) / "mariadb" / "bin" / "mariadbd",
            "PostgreSQL pg_ctl"  : Path(self.stack_dir) / "postgresql" / "bin" / "pg_ctl",
        }
        for name, path in components.items():
            mark = "✓" if path.exists() else "❌"
            self.diag_output.append(f"{mark} {name}: {path}")

        # ── PHP binaries ────────────────────────────────────────────────
        self.diag_output.append("\n=== PHP Binaries (INSTALL_DIR) ===")
        php_bin_dir = Path(self.stack_dir) / "php"
        if php_bin_dir.exists():
            for item in sorted(php_bin_dir.iterdir()):
                if item.is_dir() and item.name.replace('.', '').isdigit() and len(item.name) <= 4:
                    php_ok  = (item / "bin" / "php").exists()
                    fpm_ok  = (item / "sbin" / "php-fpm").exists()
                    self.diag_output.append(
                        f"{'✓' if php_ok else '❌'} PHP {item.name} binary  "
                        f"{'✓' if fpm_ok else '❌'} FPM")
        else:
            self.diag_output.append("❌ PHP directory not found in INSTALL_DIR")

        # ── Runtime config (user_dir) ───────────────────────────────────
        self.diag_output.append("\n=== Runtime Config (USER_DIR) ===")
        nginx_conf   = Path(self.user_dir) / "nginx" / "nginx.conf"
        mariadb_cnf  = Path(self.user_dir) / "mariadb" / "my.cnf"
        pg_data      = Path(self.user_dir) / "postgresql" / "data"

        self.diag_output.append(
            f"{'✓' if nginx_conf.exists() else '❌'} nginx/nginx.conf")
        self.diag_output.append(
            f"{'✓' if mariadb_cnf.exists() else '❌'} mariadb/my.cnf")
        self.diag_output.append(
            f"{'✓' if (pg_data / 'PG_VERSION').exists() else '❌'} postgresql/data (initialised)")

        # ── MariaDB config sanity ───────────────────────────────────────
        if mariadb_cnf.exists():
            with open(mariadb_cnf) as f:
                mc = f.read()
            if '/tmp/mysql.sock' in mc:
                self.diag_output.append("❌ MariaDB still using system socket /tmp/mysql.sock")
            else:
                self.diag_output.append("✓ MariaDB using isolated socket")

        # ── PHP current symlink ─────────────────────────────────────────
        self.diag_output.append("\n=== PHP Current Symlink (USER_DIR) ===")
        current_php = Path(self.user_dir) / "php" / "current"
        if current_php.is_symlink():
            try:
                target = current_php.resolve()
                self.diag_output.append(f"✓ current → {target.name}")
                log_dir = Path(self.user_dir) / "php" / target.name / "logs"
                if log_dir.exists():
                    self.diag_output.append(f"✓ log dir exists: {log_dir}")
                else:
                    self.diag_output.append(f"❌ log dir missing (will be auto-created on start): {log_dir}")
                fpm_conf = Path(self.user_dir) / "php" / target.name / "php-fpm.conf"
                if fpm_conf.exists():
                    self.diag_output.append(f"✓ php-fpm.conf exists")
                else:
                    self.diag_output.append(f"❌ php-fpm.conf missing: {fpm_conf}")
            except Exception:
                self.diag_output.append("❌ current symlink is broken")
        elif current_php.exists():
            self.diag_output.append("❌ current is not a symlink")
        else:
            self.diag_output.append("❌ current symlink does not exist")

        # ── Dependencies ────────────────────────────────────────────────
        self.diag_output.append("\n=== Dependencies ===")
        deps_lib = Path(self.deps_dir) / "lib"
        if deps_lib.exists():
            so_count = len(list(deps_lib.glob("*.so*")))
            self.diag_output.append(f"✓ deps/lib exists ({so_count} .so files)")
            icu_files = sorted(deps_lib.glob("libicu*"))
            if icu_files:
                self.diag_output.append(f"✓ ICU libraries: {', '.join(f.name for f in icu_files[:4])}")
            else:
                self.diag_output.append("❌ No ICU libraries found")
        else:
            self.diag_output.append("❌ deps/lib missing")

        # ── ICU via PHP ─────────────────────────────────────────────────
        self.diag_output.append("\n=== ICU via PHP ===")
        self.diag_output.append(self.check_icu_via_php())

        self.diag_output.append("\n=== Diagnostics Complete ===")

    def auto_repair(self):
        """Attempt to automatically repair common issues"""
        self.diag_output.append("\n=== Auto-Repair ===")

        # Fix PHP symlinks
        self.fix_php_symlinks()

        # Fix MariaDB config
        self.fix_mysql_socket()

        # Ensure required runtime directories exist in user_dir
        required_dirs = [
            Path(self.user_dir) / "nginx" / "logs",
            Path(self.user_dir) / "mariadb" / "logs",
            Path(self.user_dir) / "mariadb" / "data",
            Path(self.user_dir) / "postgresql" / "logs",
            Path(self.user_www),
        ]
        # PHP log dirs for all installed versions
        php_bin_dir = Path(self.stack_dir) / "php"
        if php_bin_dir.exists():
            for item in php_bin_dir.iterdir():
                if item.is_dir() and item.name.replace('.', '').isdigit():
                    required_dirs.append(
                        Path(self.user_dir) / "php" / item.name / "logs")

        for dir_path in required_dirs:
            if not dir_path.exists():
                dir_path.mkdir(parents=True, exist_ok=True)
                self.diag_output.append(f"✓ Created directory: {dir_path}")

        # Initialise MariaDB database if data dir is empty
        mysql_data_dir = Path(self.user_dir) / "mariadb" / "data"
        if mysql_data_dir.exists() and not any(mysql_data_dir.iterdir()):
            self.diag_output.append("Initialising MariaDB database...")
            self.initialize_mysql_database()

        self.diag_output.append("✓ Auto-repair completed")

    def initialize_mysql_database(self):
        """Initialize MariaDB database if it doesn't exist"""
        try:
            mysql_install_db = Path(self.stack_dir) / "mariadb" / "scripts" / "mariadb-install-db"
            if not mysql_install_db.exists():
                self.log_message("MariaDB install script not found")
                return
            env = self.get_environment()
            result = subprocess.run([
                str(mysql_install_db),
                f"--basedir={Path(self.stack_dir) / 'mariadb'}",
                f"--datadir={Path(self.user_dir) / 'mariadb' / 'data'}",
                f"--user={os.environ.get('USER', os.environ.get('LOGNAME', 'demo'))}",
            ], capture_output=True, text=True, env=env)
            if result.returncode == 0:
                self.log_message("MariaDB database initialised successfully")
            else:
                self.log_message(
                    f"MariaDB database initialisation failed: {result.stderr}")
        except Exception as e:
            self.log_message(f"Error initialising MariaDB database: {e}")

    def fix_php_symlinks(self):
        """Fix PHP version symlinks — user_dir symlink, stack_dir binaries"""
        # Binaries are in stack_dir; user_dir holds the current symlink
        php_bin_dir  = Path(self.stack_dir) / "php"
        php_user_dir = Path(self.user_dir)  / "php"
        current_link = php_user_dir / "current"

        if not php_bin_dir.exists():
            QMessageBox.warning(self, "Fix Symlinks",
                "PHP binary directory not found in INSTALL_DIR!")
            return

        php_versions = []
        for item in sorted(php_bin_dir.iterdir()):
            if item.is_dir() and item.name.replace('.', '').isdigit() and len(item.name) <= 4:
                if (item / "bin" / "php").exists():
                    php_versions.append(item.name)

        if not php_versions:
            QMessageBox.warning(self, "Fix Symlinks",
                "No valid PHP installations found in INSTALL_DIR!")
            return

        # Remove broken symlink
        if current_link.exists() or current_link.is_symlink():
            try:
                if current_link.is_symlink():
                    current_link.unlink()
                else:
                    shutil.rmtree(current_link)
            except Exception as e:
                self.log_message(f"Error removing old symlink: {e}")

        # Create new symlink  (points to user_dir/php/<ver>)
        try:
            target_version = php_versions[0]
            php_user_dir.mkdir(parents=True, exist_ok=True)
            current_link.symlink_to(php_user_dir / target_version)
            self.log_message(f"Fixed PHP symlink to version {target_version}")
            QMessageBox.information(self, "Fix Symlinks",
                f"PHP symlink fixed to version {target_version}")
        except Exception as e:
            self.log_message(f"Error creating symlink: {e}")
            QMessageBox.critical(self, "Fix Symlinks",
                f"Failed to create symlink: {e}")

    def test_nginx_config(self):
        """Test Nginx configuration"""
        try:
            env = self.get_environment()
            nginx_binary = Path(self.stack_dir) / "nginx" / "nginx"
            nginx_conf   = Path(self.user_dir)  / "nginx" / "nginx.conf"
            if not nginx_binary.exists():
                QMessageBox.warning(self, "Test Nginx", "Nginx binary not found!")
                return
            if not nginx_conf.exists():
                QMessageBox.warning(self, "Test Nginx",
                    f"Nginx config not found: {nginx_conf}")
                return
            result = subprocess.run(
                [str(nginx_binary), "-t", "-c", str(nginx_conf)],
                capture_output=True, text=True, env=env)
            if result.returncode == 0:
                QMessageBox.information(self, "Test Nginx",
                    "Nginx configuration test passed!")
            else:
                QMessageBox.critical(self, "Test Nginx",
                    f"Nginx configuration test failed:\n{result.stderr}")
        except Exception as e:
            QMessageBox.critical(self, "Test Nginx",
                f"Error testing Nginx: {e}")

    def test_php(self):
        """Test PHP installation"""
        try:
            env = self.get_environment()
            # Resolve active version from user_dir symlink, binary from stack_dir
            current_link = Path(self.user_dir) / "php" / "current"
            if not current_link.exists():
                QMessageBox.warning(self, "Test PHP",
                    "PHP 'current' symlink not found in USER_DIR!")
                return
            ver = current_link.resolve().name
            current_php = Path(self.stack_dir) / "php" / ver / "bin" / "php"
            if not current_php.exists():
                QMessageBox.warning(self, "Test PHP",
                    f"PHP binary not found: {current_php}")
                return
            result = subprocess.run([str(current_php), "-v"],
                                    capture_output=True, text=True, env=env)
            if result.returncode == 0:
                version_line = result.stdout.split('\n')[0]
                QMessageBox.information(self, "Test PHP",
                    f"PHP test passed!\n{version_line}")
            else:
                QMessageBox.critical(self, "Test PHP",
                    f"PHP test failed:\n{result.stderr}")
        except Exception as e:
            QMessageBox.critical(self, "Test PHP",
                f"Error testing PHP: {e}")

    def test_mysql(self):
        """Test MariaDB connection"""
        try:
            env = self.get_environment()
            mysql_admin  = Path(self.stack_dir) / "mariadb" / "bin" / "mariadb-admin"
            mysql_cnf    = Path(self.user_dir)  / "mariadb" / "my.cnf"
            mysql_socket = Path(self.user_dir)  / "mariadb" / "mariadb.sock"
            if not mysql_admin.exists():
                QMessageBox.warning(self, "Test MariaDB",
                    "MariaDB admin binary not found!")
                return
            result = subprocess.run(
                [str(mysql_admin),
                 f"--defaults-file={mysql_cnf}",
                 f"--socket={mysql_socket}",
                 "ping"],
                capture_output=True, text=True, env=env)
            if result.returncode == 0:
                QMessageBox.information(self, "Test MariaDB",
                    "MariaDB test passed! Server is reachable.")
            else:
                QMessageBox.critical(self, "Test MariaDB",
                    f"MariaDB test failed:\n{result.stderr}")
        except Exception as e:
            QMessageBox.critical(self, "Test MariaDB",
                f"Error testing MariaDB: {e}")

    def load_settings(self):
        """Load application settings"""
        # Load window geometry
        geometry = self.settings.value("geometry")
        if geometry:
            self.restoreGeometry(geometry)
            
        # Load behavior settings
        self.start_minimized.setChecked(self.settings.value("start_minimized", False, type=bool))
        self.auto_start.setChecked(self.settings.value("auto_start", False, type=bool))
        self.auto_stop.setChecked(self.settings.value("auto_stop", True, type=bool))
        self.auto_load_env.setChecked(self.settings.value("auto_load_env", True, type=bool))
        
        # Load ports
        self.nginx_port.setValue(self.settings.value("nginx_port", 8080, type=int))
        self.mysql_port.setValue(self.settings.value("mysql_port", 3306, type=int))
        self.pgsql_port.setValue(self.settings.value("pgsql_port", 5432, type=int))
        
        # Update web URL with loaded port
        nginx_port = self.settings.value("nginx_port", 8080, type=int)
        self.web_url.setText(f"http://localhost:{nginx_port}")
        
        # Load auto-cleanup settings
        self.auto_clean_logs.setChecked(self.settings.value("auto_clean_logs", False, type=bool))
        self.auto_clean_temp.setChecked(self.settings.value("auto_clean_temp", False, type=bool))
        
        # Populate PHP versions
        self.populate_php_versions()
        
        # Auto-load environment if configured
        if self.auto_load_env.isChecked():
            self.load_environment()
        
        # Auto-start if configured
        if self.auto_start.isChecked():
            QTimer.singleShot(1000, self.start_all_services)

    def save_settings(self):
        """Save application settings"""
        self.settings.setValue("geometry", self.saveGeometry())
        self.settings.setValue("start_minimized", self.start_minimized.isChecked())
        self.settings.setValue("auto_start", self.auto_start.isChecked())
        self.settings.setValue("auto_stop", self.auto_stop.isChecked())
        self.settings.setValue("auto_load_env", self.auto_load_env.isChecked())
        self.settings.setValue("auto_clean_logs", self.auto_clean_logs.isChecked())
        self.settings.setValue("auto_clean_temp", self.auto_clean_temp.isChecked())
        self.settings.setValue("nginx_port", self.nginx_port.value())
        self.settings.setValue("mysql_port", self.mysql_port.value())
        self.settings.setValue("pgsql_port", self.pgsql_port.value())
        
        QMessageBox.information(self, "Settings", "Settings saved successfully!")
        
    def reset_settings(self):
        """Reset settings to defaults"""
        reply = QMessageBox.question(
            self, 
            "Reset Settings", 
            "Are you sure you want to reset all settings to defaults?",
            QMessageBox.Yes | QMessageBox.No
        )
        
        if reply == QMessageBox.Yes:
            self.settings.clear()
            self.load_settings()
            QMessageBox.information(self, "Settings", "Settings reset to defaults!")
            
    def populate_php_versions(self):
        """Populate PHP version combo box from installed versions in stack_dir"""
        self.php_version_combo.clear()
        php_dir = Path(self.stack_dir) / "php"
        if php_dir.exists():
            for item in sorted(php_dir.iterdir()):
                if item.is_dir() and item.name.replace('.', '').isdigit() and len(item.name) <= 4:
                    if (item / "bin" / "php").exists():
                        self.php_version_combo.addItem(item.name)
        # Fallback: read from user_dir current symlink
        if self.php_version_combo.count() == 0:
            current_link = Path(self.user_dir) / "php" / "current"
            if current_link.exists() and current_link.is_symlink():
                try:
                    self.php_version_combo.addItem(current_link.resolve().name)
                except Exception:
                    pass
        # Set combo to currently active version
        current_link = Path(self.user_dir) / "php" / "current"
        if current_link.exists() and current_link.is_symlink():
            try:
                active = current_link.resolve().name
                idx = self.php_version_combo.findText(active)
                if idx >= 0:
                    self.php_version_combo.blockSignals(True)
                    self.php_version_combo.setCurrentIndex(idx)
                    self.php_version_combo.blockSignals(False)
            except Exception:
                pass

    def check_mysql_status(self):
        """Check if MariaDB is running by testing the socket"""
        mysql_socket = Path(self.user_dir) / "mariadb" / "mariadb.sock"
        if not mysql_socket.exists():
            return False
        try:
            env = self.get_environment()
            mysql_admin = Path(self.stack_dir) / "mariadb" / "bin" / "mariadb-admin"
            if not mysql_admin.exists():
                return False
            result = subprocess.run(
                [str(mysql_admin), f"--socket={mysql_socket}", "ping"],
                capture_output=True, text=True, env=env)
            return result.returncode == 0
        except Exception:
            return False

    def update_status(self):
        """Update service status indicators"""
        # Check stack health
        self.check_stack_health()

        # Check Nginx  (PID written to ~/.webstack/nginx/nginx.pid)
        nginx_pid_file = Path(self.user_dir) / "nginx" / "nginx.pid"
        if nginx_pid_file.exists():
            self.nginx_status.setText("Running")
            self.nginx_status.setStyleSheet("color: green; font-weight: bold;")
        else:
            self.nginx_status.setText("Stopped")
            self.nginx_status.setStyleSheet("color: red; font-weight: bold;")

        # Check PHP-FPM  (symlink ~/.webstack/php/current → ~/.webstack/php/8.x)
        php_current_link = Path(self.user_dir) / "php" / "current"
        if php_current_link.exists():
            php_pid_file = php_current_link / "php-fpm.pid"
            if php_pid_file.exists():
                self.php_status.setText("Running")
                self.php_status.setStyleSheet("color: green; font-weight: bold;")
            else:
                self.php_status.setText("Stopped")
                self.php_status.setStyleSheet("color: red; font-weight: bold;")
            try:
                php_version = php_current_link.resolve().name
                self.php_version.setText(php_version)
            except Exception:
                self.php_version.setText("Broken symlink")
        else:
            self.php_status.setText("Not installed")
            self.php_status.setStyleSheet("color: orange; font-weight: bold;")
            self.php_version.setText("Unknown")

        # Check MariaDB  (socket at ~/.webstack/mariadb/mariadb.sock)
        if self.check_mysql_status():
            self.mysql_status.setText("Running")
            self.mysql_status.setStyleSheet("color: green; font-weight: bold;")
        else:
            self.mysql_status.setText("Stopped")
            self.mysql_status.setStyleSheet("color: red; font-weight: bold;")

        # Check PostgreSQL  (PID at ~/.webstack/postgresql/data/postmaster.pid)
        if self.check_postgresql_status():
            self.pgsql_status.setText("Running")
            self.pgsql_status.setStyleSheet("color: green; font-weight: bold;")
        else:
            self.pgsql_status.setText("Stopped")
            self.pgsql_status.setStyleSheet("color: red; font-weight: bold;")

    def check_stack_health(self):
        """Check overall stack health"""
        issues = []

        if not Path(self.stack_dir).exists():
            self.stack_health.setText("Missing (INSTALL_DIR)")
            self.stack_health.setStyleSheet("color: red; font-weight: bold;")
            return

        if not Path(self.user_dir).exists():
            self.stack_health.setText("Missing (USER_DIR — run installer Phase 2)")
            self.stack_health.setStyleSheet("color: red; font-weight: bold;")
            return

        # Binaries live in stack_dir
        if not (Path(self.stack_dir) / "nginx" / "nginx").exists():
            issues.append("Nginx binary missing")
        if not (Path(self.stack_dir) / "mariadb" / "bin" / "mariadbd-safe").exists():
            issues.append("MariaDB binary missing")
        if not (Path(self.stack_dir) / "postgresql" / "bin" / "postgres").exists():
            issues.append("PostgreSQL binary missing")

        php_dir = Path(self.stack_dir) / "php"
        php_installed = False
        if php_dir.exists():
            for item in php_dir.iterdir():
                if item.is_dir() and item.name.replace('.', '').isdigit():
                    if (item / "bin" / "php").exists():
                        php_installed = True
                        break
        if not php_installed:
            issues.append("PHP binary missing")

        if not (Path(self.stack_dir) / "deps" / "lib").exists():
            issues.append("Libraries missing")

        # Runtime data lives in user_dir
        if not (Path(self.user_dir) / "nginx" / "nginx.conf").exists():
            issues.append("Nginx config missing (run installer Phase 2)")
        if not (Path(self.user_dir) / "mariadb" / "my.cnf").exists():
            issues.append("MariaDB config missing (run installer Phase 2)")

        if issues:
            self.stack_health.setText(f"Issues: {', '.join(issues)}")
            self.stack_health.setStyleSheet("color: orange; font-weight: bold;")
        else:
            self.stack_health.setText("Healthy")
            self.stack_health.setStyleSheet("color: green; font-weight: bold;")
            
    def start_service(self, service):
        """Start a specific service"""
        try:
            env = self.get_environment()

            if service == "nginx":
                nginx_binary = Path(self.stack_dir) / "nginx" / "nginx"
                nginx_conf   = Path(self.user_dir)  / "nginx" / "nginx.conf"
                if not nginx_binary.exists():
                    QMessageBox.warning(self, "Start Nginx", "Nginx binary not found!")
                    return
                if not nginx_conf.exists():
                    QMessageBox.warning(self, "Start Nginx",
                        f"Nginx config not found at {nginx_conf}\n"
                        "Re-run the installer to complete Phase 2.")
                    return
                subprocess.Popen([str(nginx_binary), "-c", str(nginx_conf)], env=env)

            elif service == "php":
                # Binaries in stack_dir; FPM config/PID/socket in user_dir
                php_user_current  = Path(self.user_dir)  / "php" / "current"
                php_inst_current  = Path(self.stack_dir) / "php" / "current"
                if not php_user_current.exists():
                    QMessageBox.warning(self, "Start PHP",
                        "PHP 'current' symlink not found in USER_DIR!\n"
                        "Use 'Fix Symlinks' or re-run the installer.")
                    return
                # Resolve the version (e.g. "8.5") from the user_dir symlink
                try:
                    ver = php_user_current.resolve().name
                except Exception:
                    QMessageBox.warning(self, "Start PHP", "PHP current symlink is broken.")
                    return
                php_fpm_bin  = Path(self.stack_dir) / "php" / ver / "sbin" / "php-fpm"
                php_fpm_conf = Path(self.user_dir)  / "php" / ver / "php-fpm.conf"
                if not php_fpm_bin.exists():
                    QMessageBox.warning(self, "Start PHP",
                        f"PHP-FPM binary not found: {php_fpm_bin}")
                    return
                if not php_fpm_conf.exists():
                    QMessageBox.warning(self, "Start PHP",
                        f"PHP-FPM config not found: {php_fpm_conf}\n"
                        "Re-run the installer to complete Phase 2.")
                    return
                # Ensure log dir exists (fixes the broken brace-expansion bug)
                log_dir = Path(self.user_dir) / "php" / ver / "logs"
                log_dir.mkdir(parents=True, exist_ok=True)
                subprocess.Popen([str(php_fpm_bin), "-y", str(php_fpm_conf)], env=env)

            elif service == "postgresql":
                pg_ctl  = Path(self.stack_dir) / "postgresql" / "bin" / "pg_ctl"
                pgdata  = Path(self.user_dir)  / "postgresql" / "data"
                pglog   = Path(self.user_dir)  / "postgresql" / "logs" / "postgresql.log"
                if not pg_ctl.exists():
                    QMessageBox.warning(self, "Start PostgreSQL",
                        "PostgreSQL pg_ctl not found!")
                    return
                if not pgdata.exists() or not (pgdata / "PG_VERSION").exists():
                    QMessageBox.warning(self, "Start PostgreSQL",
                        "PostgreSQL data directory not initialised.\n"
                        "Re-run the installer to complete Phase 2.")
                    return
                pglog.parent.mkdir(parents=True, exist_ok=True)
                subprocess.Popen(
                    [str(pg_ctl), "-D", str(pgdata), "-l", str(pglog), "start"],
                    env=env)

            elif service == "mysql":
                mysql_safe = Path(self.stack_dir) / "mariadb" / "bin" / "mariadbd-safe"
                mysql_cnf  = Path(self.user_dir)  / "mariadb" / "my.cnf"
                if not mysql_safe.exists():
                    QMessageBox.warning(self, "Start MariaDB",
                        "MariaDB mariadbd-safe binary not found!")
                    return
                if not mysql_cnf.exists():
                    QMessageBox.warning(self, "Start MariaDB",
                        f"MariaDB config not found: {mysql_cnf}\n"
                        "Re-run the installer to complete Phase 2.")
                    return
                startup_log = Path(self.user_dir) / "mariadb" / "logs" / "startup.log"
                startup_log.parent.mkdir(parents=True, exist_ok=True)
                with open(startup_log, "w") as log_file:
                    subprocess.Popen(
                        [str(mysql_safe), f"--defaults-file={mysql_cnf}"],
                        env=env, stdout=log_file, stderr=log_file)

            self.log_message(f"Started {service} service")

        except Exception as e:
            self.log_message(f"Error starting {service}: {str(e)}")
            QMessageBox.critical(self, f"Start {service}",
                f"Failed to start {service}: {str(e)}")

    def stop_service(self, service):
        """Stop a specific service"""
        try:
            env = self.get_environment()

            if service == "nginx":
                nginx_pid_file = Path(self.user_dir) / "nginx" / "nginx.pid"
                if nginx_pid_file.exists():
                    with open(nginx_pid_file) as f:
                        pid = int(f.read().strip())
                    os.kill(pid, signal.SIGTERM)

            elif service == "php":
                php_pid_file = Path(self.user_dir) / "php" / "current" / "php-fpm.pid"
                if php_pid_file.exists():
                    with open(php_pid_file) as f:
                        pid = int(f.read().strip())
                    os.kill(pid, signal.SIGTERM)

            elif service == "postgresql":
                pg_ctl  = Path(self.stack_dir) / "postgresql" / "bin" / "pg_ctl"
                pgdata  = Path(self.user_dir)  / "postgresql" / "data"
                if pg_ctl.exists() and pgdata.exists():
                    subprocess.run([str(pg_ctl), "-D", str(pgdata), "stop"],
                                   capture_output=True, text=True, env=env)

            elif service == "mysql":
                mysql_admin  = Path(self.stack_dir) / "mariadb" / "bin" / "mariadb-admin"
                mysql_cnf    = Path(self.user_dir)  / "mariadb" / "my.cnf"
                mysql_socket = Path(self.user_dir)  / "mariadb" / "mariadb.sock"
                if mysql_admin.exists():
                    result = subprocess.run(
                        [str(mysql_admin),
                         f"--defaults-file={mysql_cnf}",
                         f"--socket={mysql_socket}",
                         "shutdown"],
                        capture_output=True, text=True, env=env)
                    if result.returncode != 0:
                        self.log_message(
                            f"Graceful MariaDB shutdown failed: {result.stderr}")
                        mysql_pid_file = Path(self.user_dir) / "mariadb" / "mariadb.pid"
                        if mysql_pid_file.exists():
                            with open(mysql_pid_file) as f:
                                pid = int(f.read().strip())
                            os.kill(pid, signal.SIGTERM)
                else:
                    self.log_message("MariaDB admin binary not found")

            self.log_message(f"Stopped {service} service")

        except Exception as e:
            self.log_message(f"Error stopping {service}: {str(e)}")
            QMessageBox.critical(self, f"Stop {service}",
                f"Failed to stop {service}: {str(e)}")

    def restart_service(self, service):
        """Restart a specific service"""
        self.stop_service(service)
        # Wait a bit before starting
        QTimer.singleShot(1000, lambda: self.start_service(service))
        
    def start_all_services(self):
        """Start all services"""
        self.log_message("Starting all services...")
        # Make sure environment is loaded
        if self.auto_load_env.isChecked():
            self.load_environment()
            
        self.start_service("postgresql")
        self.start_service("mysql")
        QTimer.singleShot(2000, lambda: self.start_service("php"))
        QTimer.singleShot(4000, lambda: self.start_service("nginx"))
        
    def stop_all_services(self):
        """Stop all services"""
        self.log_message("Stopping all services...")
        self.stop_service("nginx")
        self.stop_service("php")
        self.stop_service("mysql")
        self.stop_service("postgresql")
        
        # Auto-cleanup if enabled
        if self.auto_clean_logs.isChecked():
            QTimer.singleShot(1000, self.clean_logs)
        if self.auto_clean_temp.isChecked():
            QTimer.singleShot(1000, self.clean_temp_files)
            
    def restart_all_services(self):
        """Restart all services"""
        self.log_message("Restarting all services...")
        self.stop_all_services()
        QTimer.singleShot(5000, self.start_all_services)
        
    def switch_php_version(self, version):
        """Switch PHP version"""
        if not version:
            return
        try:
            self.stop_service("php")
            # The symlink lives in user_dir; the target dir also in user_dir
            current_link = Path(self.user_dir) / "php" / "current"
            if current_link.exists() or current_link.is_symlink():
                current_link.unlink()
            current_link.symlink_to(Path(self.user_dir) / "php" / version)
            QTimer.singleShot(1000, lambda: self.start_service("php"))
            self.log_message(f"Switched to PHP {version}")
        except Exception as e:
            self.log_message(f"Error switching PHP version: {str(e)}")
            QMessageBox.critical(self, "PHP Switch",
                f"Failed to switch PHP version: {str(e)}")
            
    def clean_logs(self):
        """Clean log files"""
        try:
            log_dirs = [
                Path(self.user_dir) / "nginx" / "logs",
                Path(self.user_dir) / "mariadb" / "logs",
                Path(self.user_dir) / "postgresql" / "logs",
            ]
            php_user_dir = Path(self.user_dir) / "php"
            if php_user_dir.exists():
                for version_dir in php_user_dir.iterdir():
                    if version_dir.is_dir() and version_dir.name != "current":
                        log_dirs.append(version_dir / "logs")
            cleaned_files = 0
            for log_dir in log_dirs:
                if log_dir.exists():
                    for log_file in log_dir.glob("*.log"):
                        if log_file.stat().st_size > 0:
                            log_file.unlink()
                            cleaned_files += 1
            self.log_message(f"Cleaned {cleaned_files} log files")
            QMessageBox.information(self, "Clean Logs",
                f"Cleaned {cleaned_files} log files")
        except Exception as e:
            self.log_message(f"Error cleaning logs: {str(e)}")
            QMessageBox.critical(self, "Clean Logs",
                f"Failed to clean logs: {str(e)}")
            
    def clean_build_files(self):
        """Clean build files to free up space"""
        try:
            build_dir = Path(self.stack_dir) / "build"
            download_dir = Path(self.stack_dir) / "downloads"
            
            total_freed = 0
            
            if build_dir.exists():
                for item in build_dir.iterdir():
                    if item.is_file():
                        total_freed += item.stat().st_size
                        item.unlink()
                    elif item.is_dir():
                        shutil.rmtree(item)
                        # Estimate size for directories
                        total_freed += 100000000  # ~100MB estimate per build dir
                        
            if download_dir.exists():
                for item in download_dir.iterdir():
                    if item.is_file():
                        total_freed += item.stat().st_size
                        item.unlink()
                        
            freed_mb = total_freed / (1024 * 1024)
            self.log_message(f"Cleaned build files, freed ~{freed_mb:.1f} MB")
            QMessageBox.information(self, "Clean Build", f"Cleaned build files, freed ~{freed_mb:.1f} MB")
            
        except Exception as e:
            self.log_message(f"Error cleaning build files: {str(e)}")
            QMessageBox.critical(self, "Clean Build", f"Failed to clean build files: {str(e)}")
            
    def clean_temp_files(self):
        """Clean temporary files"""
        try:
            temp_dirs = [
                Path(self.user_dir) / "tmp",
                Path(self.user_dir) / "mariadb" / "tmp",
            ]
            cleaned_files = 0
            for temp_dir in temp_dirs:
                if temp_dir.exists():
                    for temp_file in temp_dir.glob("*"):
                        if temp_file.is_file():
                            temp_file.unlink()
                            cleaned_files += 1
            self.log_message(f"Cleaned {cleaned_files} temporary files")
        except Exception as e:
            self.log_message(f"Error cleaning temp files: {str(e)}")
            
    def full_cleanup(self):
        """Perform full cleanup"""
        reply = QMessageBox.question(
            self,
            "Full Cleanup",
            "This will clean logs, build files, and temporary files.\n"
            "This action cannot be undone.\n\n"
            "Continue?",
            QMessageBox.Yes | QMessageBox.No
        )
        
        if reply == QMessageBox.Yes:
            self.clean_logs()
            self.clean_build_files()
            self.clean_temp_files()
            
    def load_log(self):
        """Load log file content"""
        log_type = self.log_combo.currentText()
        
        try:
            if log_type == "nginx":
                log_file = Path(self.user_dir) / "nginx" / "logs" / "error.log"
            elif log_type == "php":
                current_link = Path(self.user_dir) / "php" / "current"
                if current_link.is_symlink():
                    ver = current_link.resolve().name
                    log_file = Path(self.user_dir) / "php" / ver / "logs" / "php-fpm.log"
                else:
                    log_file = Path(self.user_dir) / "php" / "current" / "logs" / "php-fpm.log"
            elif log_type == "mysql":
                log_file = Path(self.user_dir) / "mariadb" / "logs" / "error.log"
            elif log_type == "postgresql":
                log_file = Path(self.user_dir) / "postgresql" / "logs" / "postgresql.log"
            else:  # system
                self.log_view.setPlainText(self.get_application_log())
                return
                
            if log_file.exists():
                with open(log_file, 'r') as f:
                    content = f.read()
                self.log_view.setPlainText(content)
                # Scroll to bottom
                cursor = self.log_view.textCursor()
                cursor.movePosition(QTextCursor.End)
                self.log_view.setTextCursor(cursor)
            else:
                self.log_view.setPlainText(f"Log file not found: {log_file}")
                
        except Exception as e:
            self.log_view.setPlainText(f"Error reading log: {str(e)}")
            
    def clear_log(self):
        """Clear current log file"""
        log_type = self.log_combo.currentText()
        
        try:
            if log_type == "nginx":
                log_file = Path(self.user_dir) / "nginx" / "logs" / "error.log"
            elif log_type == "php":
                current_link = Path(self.user_dir) / "php" / "current"
                if current_link.is_symlink():
                    ver = current_link.resolve().name
                    log_file = Path(self.user_dir) / "php" / ver / "logs" / "php-fpm.log"
                else:
                    log_file = Path(self.user_dir) / "php" / "current" / "logs" / "php-fpm.log"
            elif log_type == "mysql":
                log_file = Path(self.user_dir) / "mariadb" / "logs" / "error.log"
            elif log_type == "postgresql":
                log_file = Path(self.user_dir) / "postgresql" / "logs" / "postgresql.log"
            else:
                return
                
            if log_file.exists():
                log_file.unlink()
                # Recreate empty file
                log_file.touch()
                self.load_log()
                
        except Exception as e:
            QMessageBox.critical(self, "Clear Log", f"Failed to clear log: {str(e)}")
            
    def toggle_auto_refresh(self, enabled):
        """Toggle auto-refresh for logs"""
        if enabled:
            self.log_timer = QTimer()
            self.log_timer.timeout.connect(self.load_log)
            self.log_timer.start(5000)  # Refresh every 5 seconds
        else:
            if hasattr(self, 'log_timer'):
                self.log_timer.stop()
                
    def log_message(self, message):
        """Add message to application log"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_entry = f"[{timestamp}] {message}\n"
        log_file = Path(self.user_dir) / "webstack_manager.log"
        try:
            with open(log_file, 'a') as f:
                f.write(log_entry)
        except Exception:
            pass  # Don't crash if log dir isn't ready yet

    def get_application_log(self):
        """Get application log content"""
        log_file = Path(self.user_dir) / "webstack_manager.log"
        if log_file.exists():
            with open(log_file) as f:
                return f.read()
        return "No application log entries yet."
        
    def check_postgresql_status(self):
        """Check if PostgreSQL is running via postmaster.pid"""
        pgdata = Path(self.user_dir) / "postgresql" / "data"
        pid_file = pgdata / "postmaster.pid"
        if not pid_file.exists():
            return False
        try:
            with open(pid_file, "r") as f:
                pid = int(f.readline().strip())
            # Verify the PID is actually alive
            os.kill(pid, 0)
            return True
        except (ValueError, ProcessLookupError, PermissionError, OSError):
            return False

    def test_postgresql(self):
        """Test PostgreSQL connection"""
        try:
            env = self.get_environment()
            psql   = Path(self.stack_dir) / "postgresql" / "bin" / "psql"
            pgdata = Path(self.user_dir)  / "postgresql" / "data"
            if not psql.exists():
                QMessageBox.warning(self, "Test PostgreSQL", "psql binary not found!")
                return
            result = subprocess.run(
                [str(psql), "-U", "postgres",
                 "-h", "127.0.0.1", "-c", "SELECT version();"],
                capture_output=True, text=True, env=env, timeout=5)
            if result.returncode == 0:
                version_line = (result.stdout.strip().split("\n")[2].strip()
                                if result.stdout else "")
                QMessageBox.information(self, "Test PostgreSQL",
                    f"PostgreSQL test passed!\n\n{version_line}")
            else:
                QMessageBox.critical(self, "Test PostgreSQL",
                    f"PostgreSQL test failed:\n{result.stderr.strip()}")
        except subprocess.TimeoutExpired:
            QMessageBox.critical(self, "Test PostgreSQL",
                "Connection timed out — is PostgreSQL running?")
        except Exception as e:
            QMessageBox.critical(self, "Test PostgreSQL",
                f"Error testing PostgreSQL: {e}")

    def update_postgresql_port(self, port):
        """Update PostgreSQL port in postgresql.conf"""
        pgdata   = Path(self.user_dir) / "postgresql" / "data"
        pg_conf  = pgdata / "postgresql.conf"
        
        if not pg_conf.exists():
            self.log_message("postgresql.conf not found - PostgreSQL may not be initialized")
            return
            
        with open(pg_conf, "r") as f:
            content = f.read()
        
        import re
        # Replace or insert port line
        if re.search(r"^#?port\s*=", content, re.MULTILINE):
            content = re.sub(r"^#?port\s*=.*$", f"port = {port}", content, flags=re.MULTILINE)
        else:
            content += f"\nport = {port}\n"
        
        with open(pg_conf, "w") as f:
            f.write(content)
        
        self.log_message(f"Updated PostgreSQL port to {port}")

    def closeEvent(self, event):
        """Handle application close"""
        if self.auto_stop.isChecked():
            self.stop_all_services()
            
        # Save settings
        self.settings.setValue("geometry", self.saveGeometry())
        
        # Hide to tray if enabled
        if self.start_minimized.isChecked() and event.spontaneous():
            event.ignore()
            self.hide()
            self.tray_icon.showMessage(
                "WebStack Manager",
                "Application minimized to system tray",
                QSystemTrayIcon.Information,
                2000
            )
        else:
            event.accept()
            
    def quit_application(self):
        """Quit the application completely"""
        if self.auto_stop.isChecked():
            self.stop_all_services()
        QApplication.quit()


def main():
    """Main application entry point"""
    app = QApplication(sys.argv)
    app.setApplicationName("WebStack Manager")
    app.setApplicationVersion("1.0.0")
    app.setQuitOnLastWindowClosed(False)

    # Check if running as root (warn but don't prevent)
    if os.geteuid() == 0:
        msg = QMessageBox()
        msg.setIcon(QMessageBox.Warning)
        msg.setWindowTitle("Running as Root")
        msg.setText("WebStack Manager is running as root.")
        msg.setInformativeText("It's recommended to run as a normal user. Some features may have limited functionality.")
        msg.setStandardButtons(QMessageBox.Ok)
        msg.exec_()
    
    # Create and show main window
    style = app.style()
    window = WebStackManager()
    window.setWindowIcon(style.standardIcon(QStyle.SP_ComputerIcon))
    
    # Check if start minimized is enabled
    settings = QSettings("WebStack", "Manager")
    start_minimized = settings.value("start_minimized", False, type=bool)
    
    if not start_minimized:
        window.show()
    
    # # Auto-load environment if configured
    # auto_load_env = settings.value("auto_load_env", True, type=bool)
    # if auto_load_env:
    #     window.load_environment()
    
    # # Start services if auto-start is enabled
    # auto_start = settings.value("auto_start", False, type=bool)
    # if auto_start:
    #     QTimer.singleShot(1000, window.start_all_services)
    
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
