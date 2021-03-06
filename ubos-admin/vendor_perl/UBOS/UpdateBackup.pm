#!/usr/bin/perl
#
# A temporary backup for the sole purpose of 'ubos-admin update'
#
# Copyright (C) 2014 and later, Indie Computing Corp. All rights reserved. License: see package.
#

use strict;
use warnings;

package UBOS::UpdateBackup;

use base qw( UBOS::AbstractBackup );
use fields;

use UBOS::Logging;
use UBOS::UpdateBackupContext;
use UBOS::Utils;

# Do not change the following path unless make sure that your updated
# version of the code still reads the old path as well; otherwise the
# upgrade to your change will lose data. Do not write to /tmp or
# a directory that may be erased during reboot as upgrades may involve
# reboots.

our $updateBackupDir         = '/ubos/backups/update';
our $previousUpdateBackupDir = '/var/lib/ubos/backups/update';

##
# Check that there is no old backup. If there is, emit error message and quit.
sub checkReadyOrQuit {
    my @found = ( <$updateBackupDir/*>, <$previousUpdateBackupDir/*> );

    if( @found ) {
        fatal( <<MSG );
Cannot create a temporary backup; the backup directory is not empty.
Did a previous ubos-admin operation fail? If so, please create an issue at
    https://github.com/uboslinux/ubos-admin/issues/new
To restore your data, run:
    ubos-admin update-stage2
MSG
    }
}

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
# Back up the provided sites.
# $sites: hash of siteId to site
sub create {
    my $self  = shift;
    my $sites = shift;

    trace( 'UpdateBackup::create', keys %$sites );

    $self->{startTime} = UBOS::Utils::time2string( time() );
    $self->{sites}     = $sites;

    unless( -d $updateBackupDir ) {
        UBOS::Utils::mkdirDashP( $updateBackupDir, 0700, undef, undef, 0755 );
    }

    my @filesToDelete = ();

    my $rolesOnHost = UBOS::Host::rolesOnHost();

    my $ret = 1;
    foreach my $site ( values %{$sites} ) {
        my $siteId = $site->siteId();
        UBOS::Utils::writeJsonToFile( "$updateBackupDir/$siteId.json", $site->siteJson, 0600 );

        my $appConfigs = $site->appConfigs();
        foreach my $appConfig ( @$appConfigs ) {

            my $appConfigId = $appConfig->appConfigId;
            UBOS::Utils::mkdir( "$updateBackupDir/$appConfigId", 0700 );

            foreach my $installable ( $appConfig->installables ) {
                my $packageName = $installable->packageName;

                UBOS::Utils::mkdir( "$updateBackupDir/$appConfigId/$packageName", 0700 );

                my $vars = $installable->obtainInstallableAtAppconfigVars( $appConfig, 1 );

                foreach my $roleName ( @{$installable->roleNames} ) {
                    my $role = $rolesOnHost->{$roleName};
                    if( $role ) { # don't attempt to backup anything not installed on this host
                        my $appConfigPathInBackup = "$updateBackupDir/$appConfigId/$packageName/$roleName";

                        UBOS::Utils::mkdir( $appConfigPathInBackup, 0700 );

                        my $dir = $vars->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );

                        my $appConfigItems = $installable->appConfigItemsInRole( $roleName );
                        if( $appConfigItems ) {

                            my $backupContext = UBOS::UpdateBackupContext->new( $self, $appConfigPathInBackup );

                            foreach my $appConfigItem ( @$appConfigItems ) {
                                if( !defined( $appConfigItem->{retentionpolicy} ) || !$appConfigItem->{retentionpolicy} ) {
                                    # for now, we don't care what value this field has as long as it is non-empty
                                    next;
                                }
                                my $item = $role->instantiateAppConfigurationItem( $appConfigItem, $appConfig, $installable );
                                if( $item ) {
                                    my $compress = undef;
                                    if( ref( $item ) eq 'UBOS::AppConfigurationItems::Database' ) {
                                        $compress = 'gz'; # compress database dumps
                                    }
                                    $ret &= $item->backup( $dir, $vars, $backupContext, \@filesToDelete, $compress );
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    foreach my $current ( @filesToDelete ) {
        unlink $current || error( 'Could not unlink', $current );
    }

    return $ret;
}

##
# Read the archive
# return: success or error
sub read {
    my $self = shift;

    trace( 'UpdateBackup::read' );

    $self->{sites} = {};

    foreach my $siteJsonFile ( <$updateBackupDir/*.json>, <$previousUpdateBackupDir/*.json> ) {
        my $siteJson = UBOS::Utils::readJsonFromFile( $siteJsonFile );
        if( $siteJson ) {
            my $site = UBOS::Site->new( $siteJson );
            if( $site ) {
                $self->{sites}->{$site->siteId()} = $site;
            } else {
                error( $@ );
            }
        }
    }

    return 1;
}

##
# Restore a single AppConfiguration from Backup.
# $siteIdInBackup: the site id of the AppConfiguration to restore, as it is stored in the Backup
# $siteIdOnHost: the site id of the AppConfiguration to restore, on the host
# $appConfigInBackup: the AppConfiguration to restore, as it is stored in the Backup
# $appConfigOnHost: the AppConfiguration to restore to, on the host
# $migrationTable: hash of old package names to new packages names, for migrations
# return: success or fail
sub restoreAppConfiguration {
    my $self              = shift;
    my $siteIdInBackup    = shift;
    my $siteIdOnHost      = shift;
    my $appConfigInBackup = shift;
    my $appConfigOnHost   = shift;
    my $migrationTable    = shift; # can be ignored here; migrations never occur during upgrades today

    my $ret                 = 1;
    my $appConfigIdInBackup = $appConfigInBackup->appConfigId;

    trace( 'UpdateBackup::restoreAppConfiguration', $appConfigIdInBackup );

    my $rolesOnHost = UBOS::Host::rolesOnHost();
    foreach my $installable ( $appConfigInBackup->installables ) {
        my $packageName = $installable->packageName;

        my $updateBackupPackageDir = "$updateBackupDir/$appConfigIdInBackup/$packageName";
        unless( -d $updateBackupPackageDir ) {
            $updateBackupPackageDir = "$previousUpdateBackupDir/$appConfigIdInBackup/$packageName";
        }
        unless( -d $updateBackupPackageDir ) {
            next;
        }

        my $vars = $installable->obtainInstallableAtAppconfigVars( $appConfigOnHost, 1 );

        foreach my $roleName ( @{$installable->roleNames} ) {
            my $role = $rolesOnHost->{$roleName};
            if( $role ) { # don't attempt to restore anything not installed on this host
                my $appConfigPathInBackup = "$updateBackupPackageDir/$roleName";
                unless( -d $appConfigPathInBackup ) {
                    next;
                }

                my $appConfigItems = $installable->appConfigItemsInRole( $roleName );
                if( $appConfigItems ) {
                    my $dir = $vars->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );

                    my $backupContext = UBOS::UpdateBackupContext->new( $self, $appConfigPathInBackup );

                    foreach my $appConfigItem ( @$appConfigItems ) {
                        if( !defined( $appConfigItem->{retentionpolicy} ) || !$appConfigItem->{retentionpolicy} ) {
                            # for now, we don't care what value this field has as long as it is non-empty
                            next;
                        }
                        my $item = $role->instantiateAppConfigurationItem( $appConfigItem, $appConfigOnHost, $installable );
                        if( $item ) {
                            $ret &= $item->restore( $dir, $vars, $backupContext );
                        }
                    }
                }
            }
        }
    }
    return $ret;
}

##
# Delete the backup from the file system
sub delete {
    my $self = shift;

    trace( 'UpdateBackup::delete' );

    UBOS::Utils::deleteRecursively( <$updateBackupDir/*>, <$previousUpdateBackupDir/*> );
}

1;
