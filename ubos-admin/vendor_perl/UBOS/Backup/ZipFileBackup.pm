#!/usr/bin/perl
#
# A Backup implemented as a ZIP file
#
# This file is part of ubos-admin.
# (C) 2012-2014 Indie Computing Corp.
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

package UBOS::Backup::ZipFileBackup;

use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use UBOS::AppConfiguration;
use UBOS::Backup::ZipFileBackupContext;
use UBOS::Configuration;
use UBOS::Logging;
use UBOS::Site;
use UBOS::Utils qw( readJsonFromString writeJsonToString );
use JSON;

use base qw( UBOS::AbstractBackup );
use fields qw( zip file );

my $fileType                 = 'UBOS::Backup::ZipFileBackup;v1';
my $zipFileTypeEntry         = 'filetype';
my $zipFileStartTimeEntry    = 'starttime';
my $zipFileSiteEntry         = 'sites';
my $zipFileInstallablesEntry = 'installables';
my $zipFileAppConfigsEntry   = 'appconfigs';

##
# Constructor.
sub new {
    my $self = shift;
    
    unless( ref( $self )) {
        $self = fields::new( $self );
    }
    $self->SUPER::new();

    return $self;
}

##
# Type of backup this class understands.
# return: the type of backup
sub backupType {
    return 'ubos-backup';
}

##
# Determine the form of compression used by this backup type.
# return: the form of compression
sub compression {
    return 'zip';
}

##
# Obtain the file that holds this Backup, if any
# return: file name
sub fileName {
    my $self = shift;

    return $self->{file};
}

##
# Save the specified Sites and AppConfigurations to a file, and return the
# corresponding Backup object. If a Site has N AppConfigurations, all of those
# AppConfigurations must be listed in the $appConfigs
# array to be backed up. If they are not, only Site meta-data (but none of the AppConfiguration data)
# will be saved.
# $sites: array of Site objects
# $appConfigs: array of AppConfiguration objects
# $noTls: if 1, do not include TLS info
# $outFile: the file to save the backup to
sub create {
    my $self       = shift;
    my $sites      = shift;
    my $appConfigs = shift;
    my $noTls      = shift;
    my $outFile    = shift;

    my $ret = 1;

    debug( 'ZipFileBackup::create', $outFile );

    $self->{startTime}  = UBOS::Utils::time2string( time() );
    $self->{zip}        = Archive::Zip->new();
    $self->{sites}      = $sites;
    $self->{appConfigs} = $appConfigs;
    $self->{file}       = $outFile;

    my @filesToDelete = ();

    ##
    my $zip = $self->{zip}; # makes code shorter

    $ret &= ( $zip->addString( $fileType,                 $zipFileTypeEntry )      ? 1 : 0 );
    $ret &= ( $zip->addString( $self->{startTime} . "\n", $zipFileStartTimeEntry ) ? 1 : 0 );

    ##

    $ret &= ( $zip->addDirectory( "$zipFileSiteEntry/" ) ? 1 : 0 );

    foreach my $site ( @$sites ) {
        my $siteId = $site->siteId();
        my $siteJson;
        if( $noTls ) {
            $siteJson = $site->siteJsonWithoutTls();
        } else {
            $siteJson = $site->siteJson();
        }
        $ret &= ( $zip->addString( writeJsonToString( $siteJson ), "$zipFileSiteEntry/$siteId.json" ) ? 1 : 0 );
    }

    ##

    $ret &= ( $zip->addDirectory( "$zipFileInstallablesEntry/" ) ? 1 : 0 );

    # construct table of installables
    my %installables = ();
    foreach my $appConfig ( @$appConfigs ) {
        foreach my $installable ( $appConfig->installables ) {
            $installables{$installable->packageName} = $installable;
        }
    }
    foreach my $packageName ( keys %installables ) {
        my $installable = $installables{$packageName};

        $ret &= ( $zip->addString( writeJsonToString( $installable->installableJson()), "$zipFileInstallablesEntry/$packageName.json" ) ? 1 : 0 );
    }

    ##

    $ret &= ( $zip->addDirectory( "$zipFileAppConfigsEntry/" ) ? 1 : 0 );

    my $rolesOnHost = UBOS::Host::rolesOnHost();
    
    foreach my $appConfig ( @$appConfigs ) {
        my $appConfigId = $appConfig->appConfigId;
        $ret &= ( $zip->addString( writeJsonToString( $appConfig->appConfigurationJson()), "$zipFileAppConfigsEntry/$appConfigId.json" ) ? 1 : 0 );
        $ret &= ( $zip->addDirectory( "$zipFileAppConfigsEntry/$appConfigId/" ) ? 1 : 0 );

        foreach my $installable ( $appConfig->installables ) {
            my $packageName = $installable->packageName;
            $ret &= ( $zip->addDirectory( "$zipFileAppConfigsEntry/$appConfigId/$packageName/" ) ? 1 : 0 );

            my $config = $appConfig->obtainSubconfig(
                    "Installable=$packageName",
                    $installable->config );

            foreach my $roleName ( @{$installable->roleNames} ) {
                my $role = $rolesOnHost->{$roleName};
                if( $role ) { # don't attempt to backup anything not installed on this host
                    my $appConfigPathInZip = "$zipFileAppConfigsEntry/$appConfigId/$packageName/$roleName";
                    $ret &= ( $zip->addDirectory( "$appConfigPathInZip/" ) ? 1 : 0 );

                    my $dir = $config->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );

                    my $appConfigItems = $installable->appConfigItemsInRole( $roleName );
                    if( $appConfigItems ) {
                        my $backupContext = UBOS::Backup::ZipFileBackupContext->new( $self, $appConfigPathInZip );

                        foreach my $appConfigItem ( @$appConfigItems ) {
                            if( !defined( $appConfigItem->{retentionpolicy} ) || !$appConfigItem->{retentionpolicy} ) {
                                # for now, we don't care what value this field has as long as it is non-empty
                                next;
                            }
                            my $item = $role->instantiateAppConfigurationItem( $appConfigItem, $appConfig, $installable );
                            if( $item ) {
                                $ret &= $item->backup( $dir, $config, $backupContext, \@filesToDelete );
                            }
                        }
                    }
                }
            }
        }
    }

    $ret &= (( $zip->writeToFileNamed( $outFile ) == AZ_OK ) ? 1 : 0 );

    foreach my $current ( @filesToDelete ) {
        unless( unlink $current ) {
            error( 'Could not unlink', $current );
            $ret = 0;
        }
    }

    return $ret;
}

##
# Read the backup.
# $archive: the archive file name
# $zip: the Archive::Zip object
# return: true if successful
sub read {
    my $archive = shift;
    my $zip     = shift;

    debug( 'ZipFileBackup::read', $archive, $zip );

    my $foundFileType = $zip->contents( $zipFileTypeEntry );
    if( $foundFileType ) {
        $foundFileType =~ s!^\s+!!;
        $foundFileType =~ s!\s+$!!;

        unless( $foundFileType eq $fileType ) {
            return undef;
        }
    } else {
        return undef;
    }

    my $self = UBOS::Backup::ZipFileBackup->new();

    $self->{sites}      = {};
    $self->{appConfigs} = {};
    $self->{startTime}  = $zip->contents( $zipFileStartTimeEntry );
    $self->{file}       = $archive;
    $self->{zip}        = $zip;

    my $ret = $self;
    
    foreach my $siteJsonFile ( $self->{zip}->membersMatching( "$zipFileSiteEntry/.*\.json" )) {
        my $siteJsonContent = $self->{zip}->contents( $siteJsonFile );
        if( $siteJsonContent ) {
            my $siteJson = readJsonFromString( $siteJsonContent );
            my $site     = UBOS::Site->new( $siteJson );

            $self->{sites}->{$site->siteId()} = $site;

        } else {
            error( 'Cannot read ZIP file entry', $siteJsonFile );
            $ret = undef;
        }
    }
    foreach my $appConfigJsonFile ( $self->{zip}->membersMatching( "$zipFileAppConfigsEntry/.*\.json" )) {
        my $appConfigJsonContent = $self->{zip}->contents( $appConfigJsonFile );
        if( $appConfigJsonContent ) {
            my $appConfigJson = readJsonFromString( $appConfigJsonContent );
            my $appConfig     = UBOS::AppConfiguration->new( $appConfigJson );

            $self->{appConfigs}->{$appConfig->appConfigId()} = $appConfig;

        } else {
            error( 'Cannot read ZIP file entry', $appConfigJsonFile );
            $ret = undef;
        }
    }

    return $ret;
}

##
# Restore a single AppConfiguration from Backup.
# $siteIdInBackup: the site id of the AppConfiguration to restore, as it is stored in the Backup
# $siteIdOnHost: the site id of the AppConfiguration to restore, on the host
# $appConfigInBackup: the AppConfiguration to restore, as it is stored in the Backup
# $appConfigOnHost: the AppConfiguration to restore to, on the host
# return: success or fail
sub restoreAppConfiguration {
    my $self              = shift;
    my $siteIdInBackup    = shift;
    my $siteIdOnHost      = shift;
    my $appConfigInBackup = shift;
    my $appConfigOnHost   = shift;

    my $ret                 = 1;
    my $zip                 = $self->{zip};
    my $appConfigIdInBackup = $appConfigInBackup->appConfigId;

    debug( 'ZipFileBackup::restoreAppConfiguration', $appConfigIdInBackup );

    my $rolesOnHost = UBOS::Host::rolesOnHost();

    foreach my $installable ( $appConfigInBackup->installables ) {
        my $packageName = $installable->packageName;
        unless( $zip->memberNamed( "$zipFileAppConfigsEntry/$appConfigIdInBackup/$packageName/" )) {
            next;
        }

        my $config = $appConfigOnHost->obtainSubconfig(
                "Installable=$packageName",
                $installable->config );

        foreach my $roleName ( @{$installable->roleNames} ) {
            my $role = $rolesOnHost->{$roleName};
            if( $role ) { # don't attempt to restore anything not installed on this host
                my $appConfigPathInZip = "$zipFileAppConfigsEntry/$appConfigIdInBackup/$packageName/$roleName";
                unless( $zip->memberNamed( "$appConfigPathInZip/" )) {
                    next;
                }

                my $appConfigItems = $installable->appConfigItemsInRole( $roleName );
                if( $appConfigItems ) {
                    my $dir = $config->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );

                    my $backupContext = UBOS::Backup::ZipFileBackupContext->new( $self, $appConfigPathInZip );

                    foreach my $appConfigItem ( @$appConfigItems ) {
                        if( !defined( $appConfigItem->{retentionpolicy} ) || !$appConfigItem->{retentionpolicy} ) {
                            # for now, we don't care what value this field has as long as it is non-empty
                            next;
                        }
                        my $item = $role->instantiateAppConfigurationItem( $appConfigItem, $appConfigOnHost, $installable );
                        if( $item ) {
                            $ret &= $item->restore( $dir, $config, $backupContext );
                        }
                    }
                }
            }
        }
    }
    return $ret;
}

1;
