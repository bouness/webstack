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


class WebStackManager(QMainWindow):
    def __init__(self):
        super().__init__()
        self.stack_dir = os.path.expanduser("~/webstack")
        self.deps_dir = os.path.join(self.stack_dir, "deps")
        self.processes = {}
        self.settings = QSettings("WebStack", "Manager")
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
        """Get the proper environment for webstack services by sourcing env.sh"""
        env = os.environ.copy()
        
        # Source the env.sh file to get the correct environment
        env_sh_path = os.path.join(self.stack_dir, "env.sh")
        if os.path.exists(env_sh_path):
            try:
                # Use bash to source the env.sh and print the environment
                result = subprocess.run(
                    ['bash', '-c', f'source {env_sh_path} && env'],
                    capture_output=True, text=True, check=True
                )
                
                # Parse the environment variables from the output
                for line in result.stdout.splitlines():
                    if '=' in line:
                        key, value = line.split('=', 1)
                        env[key] = value
                        
                self.log_message("Environment loaded from env.sh")
                
            except subprocess.CalledProcessError as e:
                self.log_message(f"Error sourcing env.sh: {e}")
                # Fallback to manual environment setup
                env = self.get_fallback_environment()
        else:
            self.log_message("env.sh not found, using fallback environment")
            env = self.get_fallback_environment()
            
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
        info_layout.addRow("Stack Path:", self.stack_path)
        
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
        
        # Environment section
        env_group = QGroupBox("Environment Configuration")
        env_layout = QVBoxLayout(env_group)
        
        env_info_layout = QHBoxLayout()
        self.env_status = QLabel("Environment: Not loaded")
        env_info_layout.addWidget(self.env_status)
        
        self.load_env_btn = QPushButton("Load Environment")
        self.load_env_btn.clicked.connect(self.load_environment)
        env_info_layout.addWidget(self.load_env_btn)
        
        self.source_env_btn = QPushButton("Source env.sh")
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
        config_layout.addRow("Stack Directory:", self.stack_dir_edit)
        
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
            
            # Update Nginx configuration
            self.update_nginx_port(nginx_port)
            
            # Update MySQL configuration  
            self.update_mysql_port(mysql_port)
            
            # Update web URL display
            self.web_url.setText(f"http://localhost:{nginx_port}")
            
            self.apply_ports_btn.setEnabled(False)
            self.log_message(f"Applied port changes: Nginx={nginx_port}, MySQL={mysql_port}")
            QMessageBox.information(self, "Port Changes", 
                                f"Port changes applied successfully!\n\n"
                                f"Nginx: {nginx_port}\n"
                                f"MySQL: {mysql_port}\n\n"
                                f"Restart services for changes to take effect.")
                                
        except Exception as e:
            self.log_message(f"Error applying port changes: {e}")
            QMessageBox.critical(self, "Port Changes", f"Failed to apply port changes: {e}")

    def update_nginx_port(self, port):
        """Update Nginx configuration with new port"""
        nginx_conf = Path(self.stack_dir) / "nginx" / "conf" / "nginx.conf"
        
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
        mysql_cnf = Path(self.stack_dir) / "mariadb" / "my.cnf"
        
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
        """Create Nginx configuration file"""
        nginx_conf = Path(self.stack_dir) / "nginx" / "conf" / "nginx.conf"
        nginx_conf.parent.mkdir(parents=True, exist_ok=True)
        
        config_content = f'''worker_processes auto;
error_log logs/error.log;
pid nginx.pid;

events {{
    worker_connections 1024;
}}

http {{
    include mime.types;
    default_type application/octet-stream;

    sendfile on;
    keepalive_timeout 65;

    server {{
        listen {port};
        server_name localhost;
        root {self.stack_dir}/www;
        index index.php index.html index.htm;

        location / {{
            try_files $uri $uri/ /index.php?$query_string;
        }}

        location ~ \.php$ {{
            fastcgi_pass unix:{self.stack_dir}/php/current/php-fpm.sock;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;
        }}

        location ~ /\.ht {{
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
        self.log_combo.addItems(["nginx", "php", "mysql", "system"])
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
        """Force source the env.sh file"""
        env_sh_path = os.path.join(self.stack_dir, "env.sh")
        if os.path.exists(env_sh_path):
            try:
                # Read and display env.sh content
                with open(env_sh_path, 'r') as f:
                    env_content = f.read()
                
                self.diag_output.append("=== env.sh content ===")
                self.diag_output.append(env_content)
                self.diag_output.append("======================")
                
                # Source the environment
                env = self.get_environment()
                self.lib_path_display.setPlainText(f"LD_LIBRARY_PATH:\n{env.get('LD_LIBRARY_PATH', 'Not set')}\n\nPATH:\n{env.get('PATH', 'Not set')}")
                self.env_status.setText("Environment: Sourced from env.sh")
                self.env_status.setStyleSheet("color: green; font-weight: bold;")
                
                self.log_message("env.sh sourced successfully")
                QMessageBox.information(self, "env.sh", "Environment sourced from env.sh successfully!")
                
            except Exception as e:
                self.log_message(f"Error reading env.sh: {e}")
                QMessageBox.critical(self, "env.sh", f"Error reading env.sh: {e}")
        else:
            QMessageBox.warning(self, "env.sh", "env.sh file not found!")

    def load_environment(self):
        """Load and display the webstack environment"""
        env = self.get_environment()
        lib_path = env.get('LD_LIBRARY_PATH', 'Not set')
        path = env.get('PATH', 'Not set')
        
        self.lib_path_display.setPlainText(f"LD_LIBRARY_PATH:\n{lib_path}\n\nPATH:\n{path}")
        self.env_status.setText("Environment: Loaded")
        self.env_status.setStyleSheet("color: green; font-weight: bold;")
        
        self.log_message("WebStack environment loaded")
        
        return env

    def check_libraries(self):
        """Check for required libraries"""
        self.diag_output.append("\n=== Library Check ===")
        
        env = self.get_environment()
        
        # Check MariaDB libraries
        mariadb_binary = Path(self.stack_dir) / "mariadb" / "bin" / "mariadbd"
        if mariadb_binary.exists():
            result = subprocess.run([
                "ldd", str(mariadb_binary)
            ], capture_output=True, text=True, env=env)
            
            if "not found" in result.stdout:
                self.diag_output.append("❌ MariaDB has missing libraries:")
                for line in result.stdout.split('\n'):
                    if "not found" in line:
                        self.diag_output.append(f"  {line.strip()}")
            else:
                self.diag_output.append("✓ MariaDB libraries are available")
        else:
            self.diag_output.append("❌ MariaDB binary not found")
            
        # Check for ICU library specifically - IMPROVED SEARCH
        self.diag_output.append("\n=== ICU Library Search ===")
        
        # Look for any ICU libraries in deps directory
        icu_patterns = [
            "libicudata*",
            "libicuuc*", 
            "libicui18n*",
            "libicuio*",
            "libicutu*",
            "libicutest*"
        ]
        
        found_icu_libs = []
        for pattern in icu_patterns:
            result = subprocess.run([
                "find", self.deps_dir, "-name", pattern, "-type", "f"
            ], capture_output=True, text=True)
            
            if result.stdout.strip():
                libs_found = result.stdout.strip().split('\n')
                found_icu_libs.extend(libs_found)
                for lib in libs_found:
                    lib_name = Path(lib).name
                    self.diag_output.append(f"✓ Found: {lib_name}")
        
        if found_icu_libs:
            self.diag_output.append(f"✓ Total ICU libraries found: {len(found_icu_libs)}")
            
            # Check which specific ICU versions are available
            icu_versions = set()
            for lib_path in found_icu_libs:
                lib_name = Path(lib_path).name
                # Extract version from library name (e.g., libicudata.so.76.1)
                if '.so.' in lib_name:
                    version_part = lib_name.split('.so.')[1]
                    # Get major version (e.g., 76 from 76.1)
                    major_version = version_part.split('.')[0]
                    icu_versions.add(major_version)
            
            if icu_versions:
                self.diag_output.append(f"✓ ICU versions available: {', '.join(sorted(icu_versions))}")
        else:
            self.diag_output.append("❌ No ICU libraries found in deps directory")
            
            # Show what's actually in the lib directory
            lib_dir = Path(self.deps_dir) / "lib"
            if lib_dir.exists():
                self.diag_output.append("\n=== Contents of lib directory ===")
                so_files = list(lib_dir.glob("*.so*"))
                for so_file in sorted(so_files):
                    self.diag_output.append(f"  {so_file.name}")
        
        # Check if PHP can find ICU libraries
        php_binary = Path(self.stack_dir) / "php" / "current" / "bin" / "php"
        if php_binary.exists():
            self.diag_output.append("\n=== PHP ICU Check ===")
            
            # Test if PHP has ICU support
            result = subprocess.run([str(php_binary), "-m"], capture_output=True, text=True, env=env)
            if "intl" in result.stdout:
                self.diag_output.append("✓ PHP intl extension loaded (requires ICU)")
            else:
                self.diag_output.append("❌ PHP intl extension not loaded")
                
            # Check PHP configuration for ICU
            result = subprocess.run([str(php_binary), "-i"], capture_output=True, text=True, env=env)
            if "ICU" in result.stdout:
                self.diag_output.append("✓ PHP ICU support detected")
            else:
                self.diag_output.append("❌ PHP ICU support not detected")
                
            # Check if PHP can find libraries at runtime
            result = subprocess.run([
                "ldd", str(php_binary)
            ], capture_output=True, text=True, env=env)
            
            if "not found" in result.stdout:
                self.diag_output.append("❌ PHP has missing libraries:")
                for line in result.stdout.split('\n'):
                    if "not found" in line and "icu" in line.lower():
                        self.diag_output.append(f"  {line.strip()}")
            else:
                self.diag_output.append("✓ PHP libraries are available")
                
        self.diag_output.append("=== Library Check Complete ===")

    def fix_mysql_socket(self):
        """Fix MySQL socket configuration - UPDATED with port setting"""
        try:
            mysql_dir = Path(self.stack_dir) / "mariadb"
            my_cnf = mysql_dir / "my.cnf"
            
            # Get current port setting or use default
            current_port = getattr(self, 'mysql_port', 3306)
            if hasattr(self, 'mysql_port'):
                current_port = self.mysql_port.value()
            
            # Create comprehensive my.cnf that FORCES the correct socket and port
            my_cnf_content = f"""[client]
port={current_port}
socket={mysql_dir}/mariadb.sock

[mysqld]
basedir={mysql_dir}
datadir={mysql_dir}/data
port={current_port}
socket={mysql_dir}/mariadb.sock
pid-file={mysql_dir}/mariadb.pid
log-error={mysql_dir}/logs/error.log
tmpdir={mysql_dir}/tmp

# Security - prevent using system socket
skip-networking
bind-address=127.0.0.1

# Performance
innodb_buffer_pool_size=16M
innodb_log_file_size=48M

# Explicitly disable system socket usage
loose-skip-symbolic-links=1

[mariadb]
socket={mysql_dir}/mariadb.sock

[mariadbd]
socket={mysql_dir}/mariadb.sock

[mysql]
socket={mysql_dir}/mariadb.sock

[mysqladmin]
socket={mysql_dir}/mariadb.sock

[mysqldump]
socket={mysql_dir}/mariadb.sock

[mysqlimport]
socket={mysql_dir}/mariadb.sock

[mysqlshow]
socket={mysql_dir}/mariadb.sock

[mysqlcheck]
socket={mysql_dir}/mariadb.sock
"""
            with open(my_cnf, 'w') as f:
                f.write(my_cnf_content)
            
            self.log_message("Created comprehensive MySQL configuration file")
            
            # Ensure required directories exist
            required_dirs = [
                mysql_dir / "logs",
                mysql_dir / "tmp", 
                mysql_dir / "data"
            ]
            
            for dir_path in required_dirs:
                dir_path.mkdir(parents=True, exist_ok=True)
            
            QMessageBox.information(self, "Fix MySQL Socket", 
                                "MySQL socket configuration completely fixed!")
            
        except Exception as e:
            self.log_message(f"Error fixing MySQL socket: {e}")
            QMessageBox.critical(self, "Fix MySQL Socket", f"Failed to fix MySQL socket: {e}")

    def check_icu_via_php(self):
        """Check ICU functionality via PHP"""
        try:
            env = self.get_environment()
            php_binary = Path(self.stack_dir) / "php" / "current" / "bin" / "php"
            
            if not php_binary.exists():
                return "PHP binary not found"
                
            # Test ICU functionality with a simple PHP script
            test_script = """
            <?php
            if (extension_loaded('intl')) {
                echo "✓ intl extension loaded\\n";
                echo "✓ ICU version: " . INTL_ICU_VERSION . "\\n";
                echo "✓ ICU data version: " . INTL_ICU_DATA_VERSION . "\\n";
                
                // Test basic ICU functionality
                $coll = collator_create('en_US');
                if ($coll) {
                    echo "✓ Collator created successfully\\n";
                } else {
                    echo "❌ Collator creation failed\\n";
                }
            } else {
                echo "❌ intl extension not loaded\\n";
            }
            ?>
            """
            
            result = subprocess.run([str(php_binary), "-r", test_script], 
                                capture_output=True, text=True, env=env)
            
            return result.stdout
            
        except Exception as e:
            return f"Error testing ICU: {e}"

    def run_diagnostics(self):
        """Run comprehensive diagnostics"""
        self.diag_output.clear()
        self.diag_output.append("=== WebStack Diagnostics ===\n")
        
        # Check stack directory
        stack_path = Path(self.stack_dir)
        if not stack_path.exists():
            self.diag_output.append("❌ Stack directory does not exist!")
            return
            
        self.diag_output.append("✓ Stack directory exists")
        
        # Check env.sh
        env_sh = stack_path / "env.sh"
        if env_sh.exists():
            self.diag_output.append("✓ env.sh found")
            with open(env_sh, 'r') as f:
                env_content = f.read()
                if "LD_LIBRARY_PATH" in env_content:
                    self.diag_output.append("✓ env.sh contains LD_LIBRARY_PATH")
                else:
                    self.diag_output.append("❌ env.sh missing LD_LIBRARY_PATH")
        else:
            self.diag_output.append("❌ env.sh not found")
        
        # Check components
        components = {
            "Nginx": stack_path / "nginx" / "nginx",
            "MariaDB safe": stack_path / "mariadb" / "bin" / "mariadbd-safe",
            "MariaDB daemon": stack_path / "mariadb" / "bin" / "mariadbd",
            "PHP": stack_path / "php"
        }
        
        for name, path in components.items():
            if path.exists():
                self.diag_output.append(f"✓ {name} found at {path}")
            else:
                self.diag_output.append(f"❌ {name} not found at {path}")
        
        # Check MySQL configuration
        mysql_cnf = stack_path / "mariadb" / "my.cnf"
        if mysql_cnf.exists():
            with open(mysql_cnf, 'r') as f:
                mysql_config = f.read()
            if '/tmp/mysql.sock' in mysql_config:
                self.diag_output.append("❌ MySQL configured to use system socket (/tmp/mysql.sock)")
            else:
                self.diag_output.append("✓ MySQL using isolated socket")
                
            # Check if socket path is correctly set
            mysql_socket_path = stack_path / "mariadb" / "mariadb.sock"
            if str(mysql_socket_path) in mysql_config:
                self.diag_output.append("✓ MySQL socket path correctly configured")
            else:
                self.diag_output.append("❌ MySQL socket path not properly configured")
        else:
            self.diag_output.append("❌ MySQL configuration file missing")
        
        # Check PHP installations - ONLY show actual installed versions
        self.diag_output.append("\n=== PHP Installations ===")
        php_dir = stack_path / "php"
        if php_dir.exists():
            # Only check directories that actually exist
            for item in php_dir.iterdir():
                if item.is_dir():
                    # Check if this looks like a PHP version directory (8.4, 8.3, etc.)
                    if item.name.replace('.', '').isdigit() and len(item.name) <= 4:
                        php_binary = item / "bin" / "php"
                        php_fpm = item / "sbin" / "php-fpm"
                        
                        if php_binary.exists():
                            self.diag_output.append(f"✓ PHP {item.name} binary found")
                        else:
                            self.diag_output.append(f"❌ PHP {item.name} binary missing")
                            
                        if php_fpm.exists():
                            self.diag_output.append(f"✓ PHP {item.name} FPM found")
                        else:
                            self.diag_output.append(f"❌ PHP {item.name} FPM missing")
                    else:
                        # Skip non-version directories or full version numbers that don't exist
                        continue
        else:
            self.diag_output.append("❌ PHP directory not found")
        
        # Check current PHP symlink
        current_php = stack_path / "php" / "current"
        if current_php.exists():
            if current_php.is_symlink():
                try:
                    target = current_php.resolve()
                    self.diag_output.append(f"✓ Current PHP symlink points to: {target.name}")
                except:
                    self.diag_output.append("❌ Current PHP symlink is broken")
            else:
                self.diag_output.append("❌ Current PHP is not a symlink")
        else:
            self.diag_output.append("❌ Current PHP symlink does not exist")
            
        # Check dependencies directory
        deps_dir = stack_path / "deps"
        if deps_dir.exists():
            self.diag_output.append(f"✓ Dependencies directory exists: {deps_dir}")
            lib_dir = deps_dir / "lib"
            if lib_dir.exists():
                self.diag_output.append(f"✓ Library directory exists: {lib_dir}")
                # Count .so files
                so_files = list(lib_dir.glob("*.so*"))
                self.diag_output.append(f"✓ Found {len(so_files)} library files")
                
                # Show ICU libraries specifically
                icu_files = list(lib_dir.glob("libicu*"))
                if icu_files:
                    self.diag_output.append(f"✓ Found {len(icu_files)} ICU library files:")
                    for icu_file in sorted(icu_files):
                        self.diag_output.append(f"  - {icu_file.name}")
                else:
                    self.diag_output.append("❌ No ICU libraries found in lib directory")
            else:
                self.diag_output.append(f"❌ Library directory missing: {lib_dir}")
        else:
            self.diag_output.append(f"❌ Dependencies directory missing: {deps_dir}")
            
        # Test ICU functionality via PHP
        self.diag_output.append("\n=== ICU Functionality Test ===")
        icu_test_result = self.check_icu_via_php()
        self.diag_output.append(icu_test_result)
            
        self.diag_output.append("\n=== Diagnostics Complete ===")

    def auto_repair(self):
        """Attempt to automatically repair common issues"""
        self.diag_output.append("\n=== Auto-Repair ===")
        
        # Fix PHP symlinks
        self.fix_php_symlinks()
        
        # Fix MySQL socket
        self.fix_mysql_socket()
        
        # Create missing directories
        required_dirs = [
            Path(self.stack_dir) / "nginx" / "logs",
            Path(self.stack_dir) / "mariadb" / "logs",
            Path(self.stack_dir) / "mariadb" / "tmp",
            Path(self.stack_dir) / "mariadb" / "data",
            Path(self.stack_dir) / "www"
        ]
        
        for dir_path in required_dirs:
            if not dir_path.exists():
                dir_path.mkdir(parents=True, exist_ok=True)
                self.diag_output.append(f"✓ Created directory: {dir_path}")
        
        # Initialize MySQL database if needed
        mysql_data_dir = Path(self.stack_dir) / "mariadb" / "data"
        if not any(mysql_data_dir.iterdir()):
            self.diag_output.append("Initializing MySQL database...")
            self.initialize_mysql_database()
        
        self.diag_output.append("✓ Auto-repair completed")

    def initialize_mysql_database(self):
        """Initialize MySQL database if it doesn't exist"""
        try:
            mysql_install_db = Path(self.stack_dir) / "mariadb" / "scripts" / "mariadb-install-db"
            if not mysql_install_db.exists():
                self.log_message("MySQL install script not found")
                return
                
            env = self.get_environment()
            mysql_dir = Path(self.stack_dir) / "mariadb"
            
            result = subprocess.run([
                str(mysql_install_db),
                "--basedir=" + str(mysql_dir),
                "--datadir=" + str(mysql_dir / "data"),
                "--user=" + os.environ.get('USER', 'demo')
            ], capture_output=True, text=True, env=env)
            
            if result.returncode == 0:
                self.log_message("MySQL database initialized successfully")
            else:
                self.log_message(f"MySQL database initialization failed: {result.stderr}")
                
        except Exception as e:
            self.log_message(f"Error initializing MySQL database: {e}")

    def fix_php_symlinks(self):
        """Fix PHP version symlinks - FIXED to only use actual versions"""
        php_dir = Path(self.stack_dir) / "php"
        current_link = php_dir / "current"
        
        if not php_dir.exists():
            QMessageBox.warning(self, "Fix Symlinks", "PHP directory not found!")
            return
            
        # Find available PHP versions - only actual installed versions
        php_versions = []
        for item in php_dir.iterdir():
            if item.is_dir():
                # Only consider directories that look like PHP versions (8.4, 8.3, etc.)
                if item.name.replace('.', '').isdigit() and len(item.name) <= 4:
                    php_binary = item / "bin" / "php"
                    if php_binary.exists():
                        php_versions.append(item.name)
        
        if not php_versions:
            QMessageBox.warning(self, "Fix Symlinks", "No valid PHP installations found!")
            return
            
        # Remove broken symlink if it exists
        if current_link.exists() or current_link.is_symlink():
            try:
                if current_link.is_symlink():
                    current_link.unlink()
                else:
                    shutil.rmtree(current_link)
            except Exception as e:
                self.log_message(f"Error removing old symlink: {e}")
        
        # Create new symlink to first available version
        try:
            target_version = php_versions[0]
            current_link.symlink_to(php_dir / target_version)
            self.log_message(f"Fixed PHP symlink to version {target_version}")
            QMessageBox.information(self, "Fix Symlinks", f"PHP symlink fixed to version {target_version}")
        except Exception as e:
            self.log_message(f"Error creating symlink: {e}")
            QMessageBox.critical(self, "Fix Symlinks", f"Failed to create symlink: {e}")

    def test_nginx_config(self):
        """Test Nginx configuration"""
        try:
            env = self.get_environment()
            nginx_binary = Path(self.stack_dir) / "nginx" / "nginx"
            if not nginx_binary.exists():
                QMessageBox.warning(self, "Test Nginx", "Nginx binary not found!")
                return
                
            result = subprocess.run([str(nginx_binary), "-t"], 
                                  capture_output=True, text=True, 
                                  cwd=str(Path(self.stack_dir) / "nginx"),
                                  env=env)
            
            if result.returncode == 0:
                QMessageBox.information(self, "Test Nginx", "Nginx configuration test passed!")
            else:
                QMessageBox.critical(self, "Test Nginx", f"Nginx configuration test failed:\n{result.stderr}")
                
        except Exception as e:
            QMessageBox.critical(self, "Test Nginx", f"Error testing Nginx: {e}")

    def test_php(self):
        """Test PHP installation"""
        try:
            env = self.get_environment()
            current_php = Path(self.stack_dir) / "php" / "current" / "bin" / "php"
            if not current_php.exists():
                QMessageBox.warning(self, "Test PHP", "PHP binary not found!")
                return
                
            result = subprocess.run([str(current_php), "-v"], 
                                  capture_output=True, text=True, env=env)
            
            if result.returncode == 0:
                version_line = result.stdout.split('\n')[0]
                QMessageBox.information(self, "Test PHP", f"PHP test passed!\n{version_line}")
            else:
                QMessageBox.critical(self, "Test PHP", f"PHP test failed:\n{result.stderr}")
                
        except Exception as e:
            QMessageBox.critical(self, "Test PHP", f"Error testing PHP: {e}")

    def test_mysql(self):
        """Test MySQL installation"""
        try:
            env = self.get_environment()
            mysql_admin = Path(self.stack_dir) / "mariadb" / "bin" / "mariadb-admin"
            if not mysql_admin.exists():
                QMessageBox.warning(self, "Test MySQL", "MySQL admin binary not found!")
                return
                
            # Use the correct socket path directly
            mysql_socket = Path(self.stack_dir) / "mariadb" / "mariadb.sock"
            
            # Test using the socket path directly (no space after =)
            result = subprocess.run([str(mysql_admin), 
                                f"--socket={mysql_socket}", 
                                "ping"], 
                                capture_output=True, text=True, env=env)
            
            if result.returncode == 0:
                QMessageBox.information(self, "Test MySQL", "MySQL test passed! Server is reachable.")
            else:
                QMessageBox.critical(self, "Test MySQL", f"MySQL test failed:\n{result.stderr}")
                
        except Exception as e:
            QMessageBox.critical(self, "Test MySQL", f"Error testing MySQL: {e}")

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
        """Populate PHP version combo box - FIXED to only show actual versions"""
        self.php_version_combo.clear()
        php_dir = Path(self.stack_dir) / "php"
        
        if php_dir.exists():
            # Only add directories that are actual PHP installations
            for item in php_dir.iterdir():
                if item.is_dir():
                    # Check if this looks like a PHP version directory (8.4, 8.3, etc.)
                    if item.name.replace('.', '').isdigit() and len(item.name) <= 4:
                        php_binary = item / "bin" / "php"
                        if php_binary.exists():  # Only add if PHP binary exists
                            self.php_version_combo.addItem(item.name)
        
        # If no versions found but current symlink exists, try to use it
        if self.php_version_combo.count() == 0:
            current_link = php_dir / "current"
            if current_link.exists() and current_link.is_symlink():
                try:
                    target = current_link.resolve().name
                    self.php_version_combo.addItem(target)
                except:
                    pass

    def check_mysql_status(self):
        """Check if MySQL is running by testing the socket"""
        mysql_socket = Path(self.stack_dir) / "mariadb" / "mariadb.sock"
        
        if not mysql_socket.exists():
            return False
            
        try:
            env = self.get_environment()
            mysql_admin = Path(self.stack_dir) / "mariadb" / "bin" / "mariadb-admin"
            
            if not mysql_admin.exists():
                return False
                
            result = subprocess.run([str(mysql_admin), 
                                f"--socket={mysql_socket}", 
                                "ping"], 
                                capture_output=True, text=True, env=env)
            
            return result.returncode == 0
            
        except Exception:
            return False

    def update_status(self):
        """Update service status indicators"""
        # Check stack health
        self.check_stack_health()
        
        # Check Nginx
        nginx_pid_file = Path(self.stack_dir) / "nginx" / "nginx.pid"
        if nginx_pid_file.exists():
            self.nginx_status.setText("Running")
            self.nginx_status.setStyleSheet("color: green; font-weight: bold;")
        else:
            self.nginx_status.setText("Stopped")
            self.nginx_status.setStyleSheet("color: red; font-weight: bold;")
            
        # Check PHP-FPM
        php_current_link = Path(self.stack_dir) / "php" / "current"
        if php_current_link.exists():
            php_pid_file = php_current_link / "php-fpm.pid"
            if php_pid_file.exists():
                self.php_status.setText("Running")
                self.php_status.setStyleSheet("color: green; font-weight: bold;")
            else:
                self.php_status.setText("Stopped")
                self.php_status.setStyleSheet("color: red; font-weight: bold;")
                
            # Update PHP version
            try:
                php_version = php_current_link.resolve().name
                self.php_version.setText(php_version)
            except:
                self.php_version.setText("Broken symlink")
        else:
            self.php_status.setText("Not installed")
            self.php_status.setStyleSheet("color: orange; font-weight: bold;")
            self.php_version.setText("Unknown")
            
        # Check MariaDB using socket test
        if self.check_mysql_status():
            self.mysql_status.setText("Running")
            self.mysql_status.setStyleSheet("color: green; font-weight: bold;")
        else:
            self.mysql_status.setText("Stopped")
            self.mysql_status.setStyleSheet("color: red; font-weight: bold;")

    def check_stack_health(self):
        """Check overall stack health"""
        issues = []
        
        # Check if stack directory exists
        if not Path(self.stack_dir).exists():
            self.stack_health.setText("Missing")
            self.stack_health.setStyleSheet("color: red; font-weight: bold;")
            return
            
        # Check components
        if not (Path(self.stack_dir) / "nginx" / "nginx").exists():
            issues.append("Nginx missing")
            
        if not (Path(self.stack_dir) / "mariadb" / "bin" / "mariadbd-safe").exists():
            issues.append("MariaDB missing")
            
        # Check PHP
        php_dir = Path(self.stack_dir) / "php"
        php_installed = False
        if php_dir.exists():
            for item in php_dir.iterdir():
                if item.is_dir() and item.name.replace('.', '').isdigit():
                    if (item / "bin" / "php").exists():
                        php_installed = True
                        break
                        
        if not php_installed:
            issues.append("PHP missing")
            
        # Check dependencies
        if not (Path(self.stack_dir) / "deps" / "lib").exists():
            issues.append("Libraries missing")
            
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
                if not nginx_binary.exists():
                    QMessageBox.warning(self, "Start Nginx", "Nginx binary not found!")
                    return
                subprocess.Popen([str(nginx_binary)], 
                            cwd=str(Path(self.stack_dir) / "nginx"),
                            env=env)
                
            elif service == "php":
                php_current = Path(self.stack_dir) / "php" / "current"
                php_fpm = php_current / "sbin" / "php-fpm"
                
                if not php_current.exists():
                    QMessageBox.warning(self, "Start PHP", "PHP 'current' symlink not found! Use 'Fix Symlinks' button.")
                    return
                    
                if not php_fpm.exists():
                    QMessageBox.warning(self, "Start PHP", f"PHP-FPM binary not found at {php_fpm}")
                    return
                    
                subprocess.Popen([str(php_fpm), 
                                "-y", str(php_current / "etc" / "php-fpm.conf")],
                                env=env)
                
            elif service == "mysql":
                mysql_safe = Path(self.stack_dir) / "mariadb" / "bin" / "mariadbd-safe"
                if not mysql_safe.exists():
                    QMessageBox.warning(self, "Start MySQL", "MariaDB binary not found!")
                    return
                    
                mysql_cnf = Path(self.stack_dir) / "mariadb" / "my.cnf"
                mysql_socket = Path(self.stack_dir) / "mariadb" / "mariadb.sock"
                
                # Ensure socket directory exists
                mysql_socket.parent.mkdir(parents=True, exist_ok=True)
                
                # Start with proper environment and log output
                startup_log = Path(self.stack_dir) / "mariadb" / "logs" / "startup.log"
                with open(startup_log, "w") as log_file:
                    process = subprocess.Popen([str(mysql_safe),
                                            f"--socket={mysql_socket}",
                                            f"--pid-file={Path(self.stack_dir) / 'mariadb' / 'mariadb.pid'}",
                                            f"--datadir={Path(self.stack_dir) / 'mariadb' / 'data'}"],
                                            env=env, stdout=log_file, stderr=log_file)
                
            self.log_message(f"Started {service} service")
            
        except Exception as e:
            self.log_message(f"Error starting {service}: {str(e)}")
            QMessageBox.critical(self, f"Start {service}", f"Failed to start {service}: {str(e)}")

    def stop_service(self, service):
        """Stop a specific service"""
        try:
            env = self.get_environment()
            
            if service == "nginx":
                nginx_pid_file = Path(self.stack_dir) / "nginx" / "nginx.pid"
                if nginx_pid_file.exists():
                    with open(nginx_pid_file, 'r') as f:
                        pid = int(f.read().strip())
                    os.kill(pid, signal.SIGTERM)
                    
            elif service == "php":
                php_pid_file = Path(self.stack_dir) / "php" / "current" / "php-fpm.pid"
                if php_pid_file.exists():
                    with open(php_pid_file, 'r') as f:
                        pid = int(f.read().strip())
                    os.kill(pid, signal.SIGTERM)
                    
            elif service == "mysql":
                mysql_admin = Path(self.stack_dir) / "mariadb" / "bin" / "mariadb-admin"
                mysql_socket = Path(self.stack_dir) / "mariadb" / "mariadb.sock"
                
                if mysql_admin.exists():
                    # Try graceful shutdown using socket directly
                    result = subprocess.run([str(mysql_admin),
                                        f"--socket={mysql_socket}",
                                        "shutdown"], 
                                        capture_output=True, text=True, env=env)
                    
                    if result.returncode != 0:
                        self.log_message(f"Graceful shutdown failed, trying force kill: {result.stderr}")
                        # If graceful shutdown fails, try to kill the process
                        mysql_pid_file = Path(self.stack_dir) / "mariadb" / "mariadb.pid"
                        if mysql_pid_file.exists():
                            with open(mysql_pid_file, 'r') as f:
                                pid = int(f.read().strip())
                            os.kill(pid, signal.SIGTERM)
                else:
                    self.log_message("MySQL admin not found, cannot stop gracefully")
                
            self.log_message(f"Stopped {service} service")
            
        except Exception as e:
            self.log_message(f"Error stopping {service}: {str(e)}")
            QMessageBox.critical(self, f"Stop {service}", f"Failed to stop {service}: {str(e)}")

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
            
        self.start_service("mysql")
        QTimer.singleShot(2000, lambda: self.start_service("php"))
        QTimer.singleShot(4000, lambda: self.start_service("nginx"))
        
    def stop_all_services(self):
        """Stop all services"""
        self.log_message("Stopping all services...")
        self.stop_service("nginx")
        self.stop_service("php")
        self.stop_service("mysql")
        
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
            # Stop current PHP
            self.stop_service("php")
            
            # Update symlink
            current_link = Path(self.stack_dir) / "php" / "current"
            if current_link.exists():
                current_link.unlink()
            current_link.symlink_to(Path(self.stack_dir) / "php" / version)
            
            # Start new PHP
            QTimer.singleShot(1000, lambda: self.start_service("php"))
            
            self.log_message(f"Switched to PHP {version}")
            
        except Exception as e:
            self.log_message(f"Error switching PHP version: {str(e)}")
            QMessageBox.critical(self, "PHP Switch", f"Failed to switch PHP version: {str(e)}")
            
    def clean_logs(self):
        """Clean log files"""
        try:
            log_dirs = [
                Path(self.stack_dir) / "nginx" / "logs",
                Path(self.stack_dir) / "mariadb" / "logs"
            ]
            
            # Add PHP log directories
            php_dir = Path(self.stack_dir) / "php"
            if php_dir.exists():
                for version_dir in php_dir.iterdir():
                    if version_dir.is_dir():
                        log_dirs.append(version_dir / "logs")
            
            cleaned_files = 0
            for log_dir in log_dirs:
                if log_dir.exists():
                    for log_file in log_dir.glob("*.log"):
                        if log_file.stat().st_size > 0:
                            log_file.unlink()
                            cleaned_files += 1
                            
            self.log_message(f"Cleaned {cleaned_files} log files")
            QMessageBox.information(self, "Clean Logs", f"Cleaned {cleaned_files} log files")
            
        except Exception as e:
            self.log_message(f"Error cleaning logs: {str(e)}")
            QMessageBox.critical(self, "Clean Logs", f"Failed to clean logs: {str(e)}")
            
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
                Path(self.stack_dir) / "tmp",
                Path(self.stack_dir) / "mariadb" / "tmp"
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
                log_file = Path(self.stack_dir) / "nginx" / "logs" / "error.log"
            elif log_type == "php":
                log_file = Path(self.stack_dir) / "php" / "current" / "logs" / "php-fpm.log"
            elif log_type == "mysql":
                log_file = Path(self.stack_dir) / "mariadb" / "logs" / "error.log"
            else:  # system
                # Show application log
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
                log_file = Path(self.stack_dir) / "nginx" / "logs" / "error.log"
            elif log_type == "php":
                log_file = Path(self.stack_dir) / "php" / "current" / "logs" / "php-fpm.log"
            elif log_type == "mysql":
                log_file = Path(self.stack_dir) / "mariadb" / "logs" / "error.log"
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
        
        # Write to application log file
        log_file = Path(self.stack_dir) / "webstack_manager.log"
        with open(log_file, 'a') as f:
            f.write(log_entry)
            
    def get_application_log(self):
        """Get application log content"""
        log_file = Path(self.stack_dir) / "webstack_manager.log"
        if log_file.exists():
            with open(log_file, 'r') as f:
                return f.read()
        return "No application log entries yet."
        
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
    
    # Create and show main window
    window = WebStackManager()
    
    # Check if start minimized is enabled
    settings = QSettings("WebStack", "Manager")
    start_minimized = settings.value("start_minimized", False, type=bool)
    
    if not start_minimized:
        window.show()
    
    # Auto-load environment if configured
    auto_load_env = settings.value("auto_load_env", True, type=bool)
    if auto_load_env:
        window.load_environment()
    
    # Start services if auto-start is enabled
    auto_start = settings.value("auto_start", False, type=bool)
    if auto_start:
        QTimer.singleShot(1000, window.start_all_services)
    
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())