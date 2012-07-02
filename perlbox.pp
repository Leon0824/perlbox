# Copyright (c) 2012, Gaurav Khanna
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of the author nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

$PERL_VERSION='5.16.0'
$USER='vagrant'
$HOME="/home/${USER}"

# This is necessary due to a bug in the puppet CentOS installation
group { 'puppet': ensure => present }

import 'dependencies.pp'

include update
include setup_user
include perlbrew

class update {
    $UPDATE_ARG='update -y'
    if $operatingsystem == 'Ubuntu' {
        $UPDATE_BIN='/usr/bin/apt-get'
    } else {
        $UPDATE_BIN='/usr/bin/yum'
        # This is necessary to support CentOS 6 coming soon...
        if $osfamily == 'RedHat' and $lsbmajdistrelease == 6 {
            $UPDATE_ARG='distribution-synchronization -y'
        }
    }

    exec { 'Update Repository Packages':
        command => "${UPDATE_BIN} ${UPDATE_ARG}",
        onlyif => "/usr/bin/test -x ${UPDATE_BIN}",
        timeout => 2500
    }

    if $operatingsystem == 'Ubuntu' {
        package { 'build-essential': ensure => latest }

        exec { 'Upgrade Repository Packages':
            require => Exec['Update Repository Packages'],
            command => "${UPDATE_BIN} upgrade -y",
            onlyif => "/usr/bin/test -x ${UPDATE_BIN}",
            timeout => 2500
        }
    }
}

class setup_user {
    user { $USER:
        ensure => present,
        home => $HOME
    }

    group { $USER: ensure => present }

    file { '/home': ensure => directory }

    file { 'Home Directory Validation':
        require => File['/home'],
        ensure => directory,
        path => $HOME,
        owner => $USER,
        group => $USER,
        mode => 700,
    }
}

class perlbrew {
    $PERL_NAME="perl-${PERL_VERSION}"
    $PERLBREW_ROOT="${HOME}/perl5/perlbrew"
    $CPANM="${PERLBREW_ROOT}/perls/${PERL_NAME}/bin/cpanm"
    $PERL="${PERLBREW_ROOT}/perls/${PERL_NAME}/bin/perl"

    Exec {
        path => '/bin:/usr/bin',
        user => $USER,
        group => $USER,
        cwd => $HOME,
        #logoutput => true,
        environment => ["PERLBREW_ROOT=${PERLBREW_ROOT}", "HOME=${HOME}"]
    }

    File {
        owner => $USER,
        group => $USER,
        mode => 644
    }

    package { curl: ensure => latest }

    exec { 'Perlbrew Installation':
        require => Package['curl'],
        command => 'curl -kL http://install.perlbrew.pl | /bin/bash',
        creates => "${PERLBREW_ROOT}/bin/perlbrew"
    }

    exec { 'Perlbrew Initialization':
        require => Exec['Perlbrew Installation'],
        command => "${PERLBREW_ROOT}/bin/perlbrew init",
        creates => "${PERLBREW_ROOT}/etc/bashrc"
    }

    exec { 'Perlbrew Self Upgrade':
        require => Exec['Perlbrew Initialization'],
        command => "${PERLBREW_ROOT}/bin/perlbrew self-upgrade"
    }

    define file_append($text) {
        exec { "echo '${text}' >> ${title}":
            require => Exec['Perlbrew Self Upgrade'],
            unless => "grep '${text}' ${title}",
            onlyif => "test -w ${title}"
        }
    }

    file_append { "${HOME}/.bashrc": text => "source ${PERLBREW_ROOT}/etc/bashrc" }

    # Set `vagrant ssh' login to use perlbrew by default (turn off for debugging)
    file_append { "${HOME}/.profile": text => "perlbrew switch ${PERL_VERSION}" }
    file_append { "${HOME}/.bash_profile": text => "perlbrew switch ${PERL_VERSION}" }

    exec { 'Perl Installation':
        require => Exec['Perlbrew Self Upgrade'],
        command => "${PERLBREW_ROOT}/bin/perlbrew install -j 4 ${PERL_VERSION}",
        creates => $PERL,
        timeout => 10000
    }

    exec { 'App::cpanminus Installation':
        require => [Package['curl'], Exec['Perl Installation']],
        provider => shell,
        command => "curl -L http://cpanmin.us | ${PERL} - --self-upgrade",
        creates => $CPANM
    }

    exec { 'App::cpanminus Self Upgrade':
        require => Exec['App::cpanminus Installation'],
        command => "${CPANM} --self-upgrade"
    }

    exec { 'App::cpanoutdated Installation':
        require => Exec['App::cpanminus Self Upgrade'],
        command => "${CPANM} App::cpanoutdated"
    }

    exec { 'App::cpanoutdated Execution':
        require => Exec['App::cpanoutdated Installation'],
        command => "${PERLBREW_ROOT}/perls/${PERL_NAME}/bin/cpan-outdated"
    }

    exec { 'App::CPAN::Fresh Installation':
        require => Exec['App::cpanoutdated Execution'],
        command => "${CPANM} App::CPAN::Fresh"
    }

    exec { 'Module::CPANfile Installation':
        require => Exec['App::CPAN::Fresh Installation'],
        command => "${CPANM} Module::CPANfile"
    }

    exec { 'App::cpanminus Dependencies Installation':
        require => Exec['Module::CPANfile Installation'],
        provider => shell,
        command => "${CPANM} -q --installdeps /${USER}",
        onlyif => "test -r /${USER}/cpanfile",
        logoutput => true
    }

}

## rebuild virtualbox tools
# sudo /etc/init.d/vboxadd setup
# unless => 'grep 'vboxsf' /proc/modules

# print all puppet facts (useful for debugging)
file { "/tmp/facts.yaml":
    content => inline_template("<%= scope.to_hash.reject { |k,v| \
   !( k.is_a?(String) && v.is_a?(String) ) }.to_yaml %>"),
}