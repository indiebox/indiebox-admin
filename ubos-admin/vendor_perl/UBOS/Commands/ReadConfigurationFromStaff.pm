#!/usr/bin/perl
#
# Command that reads the device's desired configuration from a
# configuration device, called the UBOS staff
#
# This file is part of ubos-admin.
# (C) 2012-2017 Indie Computing Corp.
#
# ubos-admin is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ubos-admin is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with ubos-admin.  If not, see <http://www.gnu.org/licenses/>.
#

use strict;
use warnings;

package UBOS::Commands::ReadConfigurationFromStaff;

use Cwd;
use File::Temp;
use Getopt::Long qw( GetOptionsFromArray );
use UBOS::ConfigurationManager;
use UBOS::Host;
use UBOS::Logging;
use UBOS::Utils;

##
# Execute this command.
# return: desired exit code
sub run {
    my $cmd  = shift;
    my @args = @_;

    if ( $< != 0 ) {
        fatal( "This command must be run as root" );
    }

    my $verbose       = 0;
    my $logConfigFile = undef;
    my $target        = undef;
    my $device        = undef;

    my $parseOk = GetOptionsFromArray(
            \@args,
            'target=s'    => \$target,
            'verbose+'    => \$verbose,
            'logConfig=s' => \$logConfigFile );

    UBOS::Logging::initialize( 'ubos-admin', $cmd, $verbose, $logConfigFile );
    info( 'ubos-admin', $cmd, @_ );

    if( !$parseOk || @args > 1 || ( @args && $target ) || ( $verbose && $logConfigFile )) {
        fatal( 'Invalid invocation:', $cmd, @_, '(add --help for help)' );
    }

    my $errors = 0;

    if( $target ) {
        unless( -d $target ) {
            fatal( 'Directory does not exist:', $target );
        }

    } else {
        if( @args ) {
            $device = shift @args;
            $device = UBOS::ConfigurationManager::checkConfigurationDevice( $device );
            unless( $device ) {
                fatal( $@ );
            }

        } else {
            $device = UBOS::ConfigurationManager::guessConfigurationDevice();
            unless( $device ) {
                fatal( 'Cannot determine UBOS staff device' );
            }
        }
        debug( 'Configuration device:', $device );

        my $targetFile = File::Temp->newdir( DIR => getcwd(), UNLINK => 1 );
           $target     = $targetFile->dirname;

        if( UBOS::Utils::myexec( "mount -t vfat '$device' '$target'" )) {
            ++$errors;
        }
    }

    $errors += UBOS::ConfigurationManager::loadCurrentConfiguration( $target );

    if( $device ) {
        if( UBOS::Utils::myexec( "umount '$target'" )) {
            ++$errors;
        }
    }

    return 1;
}

##
# Return help text for this command.
# return: hash of synopsis to help text
sub synopsisHelp {
    return {
        'summary' => <<SSS,
    Configure this device with information read from a UBOS staff device.
SSS
        'detail' => <<DDD,
    This command performs similar actions would be performed when the
    device is booted with a UBOS staff device attached.
DDD
        'cmds' => {
            '' => <<HHH,
    Guess which device is the UBOS staff device.
HHH
            <<SSS => <<HHH,
    <ubos-staff-device>
SSS
    Read from the provided UBOS staff device, such as /dev/sdc.
HHH
            <<SSS => <<HHH
    --target <directory>
SSS
    Read from a directory that contains UBOS staff information instead.
HHH
        },
        'args' => {
            '--verbose' => <<HHH,
    Display extra output. May be repeated for even more output.
HHH
            '--logConfig <file>' => <<HHH
    Use an alternate log configuration file for this command.
HHH
        }
    };
}

1;
