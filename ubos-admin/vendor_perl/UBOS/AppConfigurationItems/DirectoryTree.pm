#!/usr/bin/perl
#
# An AppConfiguration item that is a directory tree.
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

package UBOS::AppConfigurationItems::DirectoryTree;

use base qw( UBOS::AppConfigurationItems::AppConfigurationItem );
use fields;

use File::Find;
use UBOS::Logging;

##
# Constructor
# $json: the JSON fragment from the manifest JSON
# $role: the Role to which this item belongs to
# $appConfig: the AppConfiguration object that this item belongs to
# $installable: the Installable to which this item belongs to
# return: the created File object
sub new {
    my $self        = shift;
    my $json        = shift;
    my $role        = shift;
    my $appConfig   = shift;
    my $installable = shift;

    unless( ref $self ) {
        $self = fields::new( $self );
    }
    $self->SUPER::new( $json, $role, $appConfig, $installable );

    return $self;
}

##
# Install this item, or check that it is installable.
# $doIt: if 1, install; if 0, only check
# $defaultFromDir: the directory to which "source" paths are relative to
# $defaultToDir: the directory to which "destination" paths are relative to
# $vars: the Variables object that knows about symbolic names and variables
# return: success or fail
sub deployOrCheck {
    my $self           = shift;
    my $doIt           = shift;
    my $defaultFromDir = shift;
    my $defaultToDir   = shift;
    my $vars           = shift;

    my $ret   = 1;
    my $names = $self->{json}->{names};
    unless( $names ) {
        $names = [ $self->{json}->{name} ];
    }
    my $source = $self->{json}->{source};

    trace( 'DirectoryTree::deployOrCheck', $doIt, $defaultFromDir, $defaultToDir, $source, @$names );

    my $filepermissions = $vars->replaceVariables( $self->{json}->{filepermissions} );
    my $dirpermissions  = $vars->replaceVariables( $self->{json}->{dirpermissions} );
    my $uname           = $vars->replaceVariables( $self->{json}->{uname} );
    my $gname           = $vars->replaceVariables( $self->{json}->{gname} );
    my $uid             = UBOS::Utils::getUid( $uname );
    my $gid             = UBOS::Utils::getGid( $gname );
    my $filemode        = ( defined( $filepermissions ) && $filepermissions eq 'preserve' ) ? -1 : $self->permissionToMode( $filepermissions, 0644 );
    my $dirmode         = ( defined( $dirpermissions  ) && $dirpermissions  eq 'preserve' ) ? -1 : $self->permissionToMode( $dirpermissions, 0755 );

    foreach my $name ( @$names ) {
        my $localName  = $name;
        $localName =~ s!^.+/!!;

        my $fromName = $source;
        $fromName =~ s!\$1!$name!g;      # $1: name
        $fromName =~ s!\$2!$localName!g; # $2: just the name without directories
        $fromName = $vars->replaceVariables( $fromName );

        my $toName = $name;
        $toName = $vars->replaceVariables( $toName );

        unless( $fromName =~ m#^/# ) {
            $fromName = "$defaultFromDir/$fromName";
        }
        unless( $toName =~ m#^/# ) {
            $toName = "$defaultToDir/$toName";
        }

        if( $doIt ) {
            $ret &= UBOS::Utils::copyRecursively( $fromName, $toName );

            if( $uid || $gid || ( defined( $filemode ) && $filemode != -1 ) || ( defined( $dirmode ) && $dirmode != -1 )) {
                find(   sub {
                            if( $uid || $gid ) {
                                chown $uid, $gid, $File::Find::name;
                            }
                            if( -d $File::Find::name ) {
                                if( defined( $dirmode ) && $dirmode != -1 ) {
                                    chmod $dirmode, $File::Find::name;
                                }
                            } else {
                                if( defined( $filemode ) && $filemode != -1 ) {
                                    chmod $filemode, $File::Find::name;
                                }
                            }
                        },
                        $toName );
            }
        }
    }
    return $ret;
}

##
# Uninstall this item, or check that it is uninstallable.
# $doIt: if 1, uninstall; if 0, only check
# $defaultFromDir: the directory to which "source" paths are relative to
# $defaultToDir: the directory to which "destination" paths are relative to
# $vars: the Variables object that knows about symbolic names and variables
# return: success or fail
sub undeployOrCheck {
    my $self           = shift;
    my $doIt           = shift;
    my $defaultFromDir = shift;
    my $defaultToDir   = shift;
    my $vars           = shift;

    my $ret   = 1;
    my $names = $self->{json}->{names};
    unless( $names ) {
        $names = [ $self->{json}->{name} ];
    }

    trace( 'DirectoryTree::undeployOrCheck', $doIt, $defaultFromDir, $defaultToDir, @$names );

    foreach my $name ( reverse @$names ) {
        my $toName = $name;

        $toName = $vars->replaceVariables( $toName );

        unless( $toName =~ m#^/# ) {
            $toName = "$defaultToDir/$toName";
        }
        if( $doIt ) {
            $ret &= UBOS::Utils::deleteRecursively( $toName );
        }
    }
    return $ret;
}

##
# Back this item up.
# $dir: the directory in which the app was installed
# $vars: the Variables object that knows about symbolic names and variables
# $backupContext: the Backup Context object
# $filesToDelete: array of filenames of temporary files that need to be deleted after backup
# return: success or fail
sub backup {
    my $self          = shift;
    my $dir           = shift;
    my $vars          = shift;
    my $backupContext = shift;
    my $filesToDelete = shift;

    my $bucket = $self->{json}->{retentionbucket};
    my $names  = $self->{json}->{names};
    unless( $names ) {
        $names = [ $self->{json}->{name} ];
    }

    trace( 'DirectoryTree::backup', $bucket, @$names );

    if( @$names != 1 ) {
        error( 'DirectoryTree::backup: cannot backup item with more than one name:', @$names );
        return 0;
    }

    my $fullName = $vars->replaceVariables( $names->[0] );
    unless( $fullName =~ m#^/# ) {
        $fullName = "$dir/$fullName";
    }

    return $backupContext->addDirectoryHierarchy( $fullName, $bucket );
}

##
# Default implementation to restore this item from backup.
# $dir: the directory in which the app was installed
# $vars: the Variables object that knows about symbolic names and variables
# $backupContext: the Backup Context object
# return: success or fail
sub restore {
    my $self          = shift;
    my $dir           = shift;
    my $vars          = shift;
    my $backupContext = shift;

    my $bucket = $self->{json}->{retentionbucket};
    my $names  = $self->{json}->{names};
    unless( $names ) {
        $names = [ $self->{json}->{name} ];
    }

    trace( 'DirectoryTree::restore', $bucket, $names );

    if( @$names != 1 ) {
        error( 'DirectoryTree::restore: cannot restore item with more than one name:', @$names );
        return 0;
    }

    my $fullName = $vars->replaceVariables( $names->[0] );
    unless( $fullName =~ m#^/# ) {
        $fullName = "$dir/$fullName";
    }

    my $filepermissions = $vars->replaceVariables( $self->{json}->{filepermissions} );
    my $dirpermissions  = $vars->replaceVariables( $self->{json}->{dirpermissions} );
    my $uname           = $vars->replaceVariables( $self->{json}->{uname} );
    my $gname           = $vars->replaceVariables( $self->{json}->{gname} );
    my $uid             = UBOS::Utils::getUid( $uname );
    my $gid             = UBOS::Utils::getGid( $gname );
    my $filemode        = ( defined( $filepermissions ) && $filepermissions eq 'preserve' ) ? -1 : $self->permissionToMode( $filepermissions, 0644 );
    my $dirmode         = ( defined( $dirpermissions  ) && $dirpermissions  eq 'preserve' ) ? -1 : $self->permissionToMode( $dirpermissions, 0755 );

    my $ret = 1;
    unless( $backupContext->restoreRecursive( $bucket, $fullName )) {
        error( 'Cannot restore directorytree: bucket:', $bucket, 'fullName:', $fullName, 'context:', $backupContext->asString() );
        $ret = 0;
    }

    if( $filemode > -1 ) {
        my $asOct = sprintf( "%o", $filemode );
        UBOS::Utils::myexec( "find '$fullName' -type f -exec chmod $asOct {} \\;" ); # no -h on Linux
    }
    if( $dirmode > -1 ) {
        my $asOct = sprintf( "%o", $dirmode );
        UBOS::Utils::myexec( "find '$fullName' -type d -exec chmod $asOct {} \\;" ); # no -h on Linux
    }

    if( defined( $uid )) {
        UBOS::Utils::myexec( 'chown -R -h ' . ( 0 + $uid ) . " $fullName" );
    }
    if( defined( $gid )) {
        UBOS::Utils::myexec( 'chgrp -R -h ' . ( 0 + $gid ) . " $fullName" );
    }
    return $ret;
}

1;
