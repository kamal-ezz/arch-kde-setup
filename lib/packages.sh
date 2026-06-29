#!/usr/bin/env bash
# Arch Linux package groups.

pkgs_system_tools() { echo "zsh git curl wget unzip tar bat fzf htop cabextract fastfetch fuse2"; }

pkgs_dev() { echo "podman python python-pip go gcc make cmake clang"; }

pkgs_java_candidates() { echo "jdk21-openjdk jdk17-openjdk jdk-openjdk"; }

pkgs_codecs() { echo "vlc vlc-plugin-ffmpeg ffmpeg gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav"; }

pkgs_gaming() { echo "gamemode mangohud lutris goverlay"; }

pkgs_steam() { echo "steam"; }

pkgs_themes() { echo "papirus-icon-theme"; }

pkgs_kde_only() {
    echo "ark discover dolphin dolphin-plugins ffmpegthumbs filelight flatpak-kcm gwenview kconfig kdeconnect kdegraphics-thumbnailers kio-admin kio-extras konsole okular plasma-browser-integration spectacle xdg-desktop-portal-kde"
}

pkgs_qt() { echo "qt5ct qt6ct"; }

pkgs_fonts_arabic() { echo "noto-fonts ttf-amiri"; }

pkgs_bluetooth() { echo "bluez bluez-utils"; }

pkgs_power() { echo "power-profiles-daemon"; }

pkgs_bloat() { echo "gnome-tour gnome-maps gnome-weather gnome-contacts gnome-clocks simple-scan"; }

pkgs_ghostty_build_deps() { echo "gtk4 gtk4-layer-shell libadwaita gettext"; }

pkgs_virt() { echo "qemu-full libvirt virt-manager bridge-utils edk2-ovmf swtpm dnsmasq"; }

pkgs_snapper() { echo "snapper snap-pac btrfs-assistant"; }

pkgs_firewall() { echo "firewalld"; }

pkgs_docker_engine() { echo "docker docker-buildx docker-compose"; }

pkgs_docker_conflicts() { echo "docker"; }

pkgs_ms_fonts() { echo "ttf-ms-fonts"; }
