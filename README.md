# WebStack Manager

A comprehensive PySide6-based GUI application for managing a portable web development stack (Nginx, PHP-FPM, MariaDB) that runs completely isolated from your system.

![WebStack Manager](https://img.shields.io/badge/WebStack-Manager-blue)
![PySide6](https://img.shields.io/badge/GUI-PySide6-green)
![Portable](https://img.shields.io/badge/Architecture-Portable-orange)

---

## 💖 Support Project
**Bitcoin:** `34Db9CqBjwiFt3SmaPUQPW4Z3QMjMrfVFh`

**Venmo:** Scan to donate via Venmo to support the project:

![Venmo QR](https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=https://venmo.com/youness-bougteb)

## 🌟 Features

### 🎯 Core Management
- **Service Control**: Start, stop, and restart Nginx, PHP-FPM, and MariaDB
- **Multiple PHP Versions**: Switch between installed PHP versions (8.2, 8.3, 8.4)
- **Real-time Status**: Live monitoring of all services with color-coded status indicators
- **System Tray Integration**: Minimize to system tray with quick access controls

### 🛠️ Advanced Features
- **Environment Management**: Automatic handling of library paths and dependencies
- **Comprehensive Diagnostics**: Detailed system health checks and troubleshooting
- **Auto-Repair**: Fix common issues like broken symlinks and socket configurations
- **Port Configuration**: Customize Nginx and MySQL ports with live updates
- **Log Management**: View and clear service logs with auto-refresh capability

### 🧹 Maintenance Tools
- **Cleanup Operations**: Clean logs, build files, and temporary files
- **Auto-cleanup**: Automatic cleanup on service stop
- **Build Management**: Clean build directories to free up disk space
- **Configuration Repair**: Fix MySQL socket and PHP symlink issues

## 📋 Requirements

### System Requirements
- **Arch Linux** (or compatible distribution)
- **Python 3.8+**
- **Basic build tools**: `gcc`, `make`

### Python Dependencies
```bash
pip install PySide6
```

## 🚀 Installation

### 1. Clone the Repository
```bash
git clone https://github.com/bouness/webstack.git
cd webstack
```

### 2. Run the Installation Script
```bash
# Make the installation script executable
chmod +x install-webstack.sh

# Run the installation (this will take 1-2 hours)
./install-webstack.sh
```

The installation script will:
- Compile all dependencies from source
- Install Nginx, PHP (multiple versions), and MariaDB
- Set up the complete isolated environment in `~/webstack`
- Create management scripts and configuration files

### 3. Start the GUI
```bash
# Run the WebStack Manager GUI
python3 cp.py
```

## 🎮 Usage

### Starting the Stack
1. Launch the WebStack Manager GUI
2. Click **"Start All"** in the Status tab
3. Access your web server at `http://localhost:8080`

### Managing Services

#### Status Tab
- View real-time service status (Running/Stopped)
- Quick actions: Start All, Stop All, Restart All
- System information and stack health

#### Control Tab
- **Individual Service Control**: Start/stop/restart each service separately
- **PHP Version Management**: Switch between installed PHP versions
- **Environment Configuration**: Load and monitor library paths
- **Maintenance Tools**: Clean logs, build files, and fix common issues

#### Diagnostics Tab
- **Run Diagnostics**: Comprehensive system health check
- **Auto-Repair**: Fix common configuration issues automatically
- **Library Check**: Verify all required libraries are available
- **ICU Check**: Test ICU library functionality for PHP internationalization

#### Settings Tab
- **Port Configuration**: Change Nginx and MySQL ports
- **Behavior Settings**: Auto-start, auto-stop, and tray behavior
- **Save/Restore**: Persistent application settings

#### Logs Tab
- View service logs (Nginx, PHP, MySQL, System)
- Auto-refresh capability
- Clear individual log files

### System Tray
- Right-click tray icon for quick actions
- Double-click to show/hide main window
- Service status indicators

## 🔧 Configuration

### Port Configuration
1. Go to **Settings** tab
2. Change Nginx port (default: 8080) or MySQL port (default: 3306)
3. Click **"Apply Port Changes"**
4. Restart services for changes to take effect

### PHP Version Switching
1. Go to **Control** tab  
2. Select desired PHP version from dropdown
3. PHP-FPM will automatically restart with the new version

### Environment Management
- Click **"Load Environment"** to set up library paths
- Use **"Source env.sh"** to force reload environment variables
- Environment is automatically loaded on application start

## 🗂️ Project Structure

```
~/webstack/
├── nginx/                 # Nginx installation
│   ├── nginx             # Nginx binary
│   ├── conf/             # Configuration files
│   └── logs/             # Access and error logs
├── php/                  # PHP installations
│   ├── 8.2/             # PHP 8.2 installation
│   ├── 8.3/             # PHP 8.3 installation  
│   ├── 8.4/             # PHP 8.4 installation
│   └── current -> 8.4/  # Active PHP version symlink
├── mariadb/              # MariaDB installation
│   ├── bin/              # Database binaries
│   ├── data/             # Database files
│   ├── logs/             # Database logs
│   └── my.cnf            # Database configuration
├── deps/                 # Compiled dependencies
│   └── lib/              # Library files
├── www/                  # Web root directory
│   └── index.php         # Test page
├── build/                # Build directory (can be cleaned)
├── downloads/            # Downloaded source files
├── bin/                  # Management scripts
├── logs/                 # Application logs
└── env.sh               # Environment setup script
```

## 🛠️ Troubleshooting

### Common Issues

#### Services Won't Start
1. Run **"Auto-Repair"** in Diagnostics tab
2. Check **"Fix MySQL Socket"** if MySQL has socket issues
3. Verify environment is loaded with **"Load Environment"**

#### Library Loading Issues
1. Use **"Check Libraries"** in Diagnostics tab
2. Ensure `env.sh` is properly sourced
3. Run **"Auto-Repair"** to fix library paths

#### PHP Version Problems
1. Use **"Fix Symlinks"** to repair PHP version links
2. Verify PHP installations in Diagnostics tab
3. Check that PHP binaries exist in respective version directories

### Manual Commands

If the GUI isn't working, you can use the command-line scripts:

```bash
# Start all services
~/.local/bin/webstack-start

# Stop all services  
~/.local/bin/webstack-stop

# Switch PHP version
~/.local/bin/webstack-php 8.3

# MySQL client
~/.local/bin/webstack-mysql
```

## 🔍 Diagnostics

The application includes comprehensive diagnostics:

### Service Checks
- Verifies all service binaries exist
- Checks configuration file integrity
- Validates socket configurations

### Library Verification
- ICU library detection and functionality testing
- PHP extension availability
- Runtime library dependency checking

### Configuration Validation
- MySQL socket path verification
- PHP symlink integrity
- Port configuration consistency

## 📊 Logging

### Application Logs
- Located at `~/webstack/webstack_manager.log`
- Tracks all GUI actions and service commands

### Service Logs
- **Nginx**: `~/webstack/nginx/logs/`
- **PHP-FPM**: `~/webstack/php/current/logs/`
- **MariaDB**: `~/webstack/mariadb/logs/`

## 🚨 Important Notes

### Isolation
- All services run completely isolated from system installations
- No root access required for installation or operation
- All dependencies are compiled from source

### Portability
- The entire stack can be moved to another machine by copying the `~/webstack` directory
- All paths are relative and self-contained

### Security
- MariaDB runs with binding to localhost only
- No external network access by default
- Isolated from system MySQL installations

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Built with [PySide6](https://www.qt.io/qt-for-python) for the GUI
- Portable compilation techniques inspired by static linking principles
- Service management patterns from production deployment best practices

## 📞 Support

If you encounter any issues:

1. Check the **Diagnostics** tab for automated troubleshooting
2. Review the application logs in `~/webstack/webstack_manager.log`
3. Check service-specific logs in their respective directories
4. Open an issue on GitHub with detailed error information

---

**WebStack Manager** - Your portable, isolated web development environment made easy! 🚀