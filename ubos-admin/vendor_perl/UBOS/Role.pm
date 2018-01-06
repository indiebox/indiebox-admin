#!/usr/bin/perl
#
# Abstract superclass for Roles.
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

package UBOS::Role;

use UBOS::AppConfigurationItems::Database;
use UBOS::AppConfigurationItems::Directory;
use UBOS::AppConfigurationItems::DirectoryTree;
use UBOS::AppConfigurationItems::File;
use UBOS::AppConfigurationItems::Perlscript;
use UBOS::AppConfigurationItems::Sqlscript;
use UBOS::AppConfigurationItems::Symlink;
use UBOS::AppConfigurationItems::SystemdService;
use UBOS::AppConfigurationItems::SystemdTimer;
use UBOS::AppConfigurationItems::TcpPort;
use UBOS::AppConfigurationItems::UdpPort;
use UBOS::Host;
use UBOS::Installable;
use UBOS::Logging;

use fields;

##
# Constructor
sub new {
    my $self = shift;

    unless( ref $self ) {
        $self = fields::new( $self );
    }
    return $self;
}

##
# Name of this Role
# return: name
sub name {
    my $self = shift;

    error( 'Role name undefined on this level, need to subclass:', ref( $self ));

    return undef;
}

##
# Is this Role always needed, regardless of what the AppConfigurations say?
# return: true or false
sub isAlwaysNeeded {
    my $self = shift;

    return 0;
}

##
# Deploy an installable in an AppConfiguration in this Role, or just check whether
# it is deployable. Both functions share the same code, so the checks get updated
# at the same time as the actual deployment.
# $doIt: if 1, deploy; if 0, only check
# $appConfig: the AppConfiguration to deploy
# $installable: the Installable
# $vars: the Variables object that knows about symbolic names and variables
# return: success or fail
sub deployOrCheck {
    my $self        = shift;
    my $doIt        = shift;
    my $appConfig   = shift;
    my $installable = shift;
    my $vars        = shift;

    # skip dependencies: done already
    my $ret      = 1;
    my $roleName = $self->name();

    trace( 'Role::deployOrCheck', $roleName, $doIt, $appConfig->appConfigId, $installable->packageName );

    if( ref( $installable ) =~ m!App! ) {
        my $siteDocumentDir = $appConfig->vars()->getResolve( "site.$roleName.sitedocumentdir", undef, 1 );
        if( $doIt && $siteDocumentDir ) {
            my $dir      = $appConfig->vars()->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );
            if( $dir && $dir ne $siteDocumentDir ) {
                UBOS::Utils::mkdir( $dir, 0755 );
            }
        }
    }

    my $installableRoleJson = $installable->installableJson->{roles}->{$roleName};
    if( $installableRoleJson ) {
        my $appConfigItems = $installableRoleJson->{appconfigitems};
        if( $appConfigItems ) {
            my $codeDir   = $vars->getResolve( 'package.codedir' );
            my $dir       = $appConfig->vars()->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );
            my $itemIndex = 0;
            foreach my $appConfigItem ( @$appConfigItems ) {
                if( $doIt ) {
                    trace( 'Role::deployOrCheck', $appConfig->appConfigId, $itemIndex );
                }
                my $item = $self->instantiateAppConfigurationItem( $appConfigItem, $appConfig, $installable );
                if( $item ) {
                    if( $doIt ) {
                        debugAndSuspend(
                                'Deploy',         $itemIndex,
                                'with role',      $roleName,
                                'of installable', $installable->packageName,
                                'at appconfig',   $appConfig->appConfigId );
                    }
                    $ret &= $item->deployOrCheck( $doIt, $codeDir, $dir, $vars );
                }
                ++$itemIndex;
            }
        }
    }
    return $ret;
}

##
# Undeploy an installable in an AppConfiguration in this Role, or just check whether
# it is undeployable. Both functions share the same code, so the checks get updated
# at the same time as the actual deployment.
# $doIt: if 1, undeploy; if 0, only check
# $appConfig: the AppConfiguration to deploy
# $installable: the Installable
# $vars: the Variables object that knows about symbolic names and variables
# return: success or fail
sub undeployOrCheck {
    my $self        = shift;
    my $doIt        = shift;
    my $appConfig   = shift;
    my $installable = shift;
    my $vars        = shift;

    my $ret      = 1;
    my $roleName = $self->name();

    trace( 'Role::undeployOrCheck', $roleName, $doIt, $appConfig->appConfigId, $installable->packageName );

    my $installableRoleJson = $installable->installableJson->{roles}->{$roleName};

    if( $installableRoleJson ) {
        my $appConfigItems = $installableRoleJson->{appconfigitems};
        if( $appConfigItems ) {
            my $codeDir = $vars->getResolve( 'package.codedir' );
            my $dir     = $vars->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );

            my $itemIndex = @$appConfigItems-1;
            foreach my $appConfigItem ( reverse @$appConfigItems ) {
                if( $doIt ) {
                    trace( 'Role::undeployOrCheck', $appConfig->appConfigId, $itemIndex );
                }
                my $item = $self->instantiateAppConfigurationItem( $appConfigItem, $appConfig, $installable );
                if( $item ) {
                    if( $doIt ) {
                        debugAndSuspend(
                                'Undeploy',       $itemIndex,
                                'with role',      $roleName,
                                'of installable', $installable->packageName,
                                'at appconfig',   $appConfig->appConfigId );
                    }
                    $ret &= $item->undeployOrCheck( $doIt, $codeDir, $dir, $vars );
                }
                --$itemIndex;
            }
        }
    }

    if( $doIt && ref( $installable ) =~ m!App! ) {
        my $siteDocumentDir = $appConfig->vars()->getResolve( "site.$roleName.sitedocumentdir", undef, 1 );
        my $dir             = $appConfig->vars()->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );

        if( $dir && $dir ne $siteDocumentDir ) {
            UBOS::Utils::rmdir( $dir );
        }
    }

    return $ret;
}

##
# Suspend an installable in an AppConfiguration in this Role.
# $appConfig: the AppConfiguration to suspend
# $installable: the Installable
# $vars: the Variables object that knows about symbolic names and variables
sub suspend {
    my $self        = shift;
    my $appConfig   = shift;
    my $installable = shift;
    my $vars        = shift;

    my $ret      = 1;
    my $roleName = $self->name();

    trace( 'Role::suspend', $roleName, $appConfig->appConfigId, $installable->packageName );

    my $installableRoleJson = $installable->installableJson->{roles}->{$roleName};
    if( $installableRoleJson ) {
        my $appConfigItems = $installableRoleJson->{appconfigitems};
        if( $appConfigItems ) {
            my $codeDir   = $vars->getResolve( 'package.codedir' );
            my $dir       = $appConfig->vars()->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );
            my $itemIndex = 0;
            foreach my $appConfigItem ( reverse @$appConfigItems ) {
                trace( 'Role::suspend', $appConfig->appConfigId, $itemIndex );

                my $item = $self->instantiateAppConfigurationItem( $appConfigItem, $appConfig, $installable );
                if( $item ) {
                    debugAndSuspend(
                            'Suspend',        $itemIndex,
                            'with role',      $roleName,
                            'of installable', $installable->packageName,
                            'at appconfig',   $appConfig->appConfigId );

                    $ret &= $item->suspend( $codeDir, $dir, $vars );
                }
                ++$itemIndex;
            }
        }
    }
    return $ret;
}

##
# Resume an installable in an AppConfiguration in this Role.
# $appConfig: the AppConfiguration to resume
# $installable: the Installable
# $vars: the Variables object that knows about symbolic names and variables
sub resume {
    my $self        = shift;
    my $appConfig   = shift;
    my $installable = shift;
    my $vars        = shift;

    my $ret      = 1;
    my $roleName = $self->name();

    trace( 'Role::resume', $roleName, $appConfig->appConfigId, $installable->packageName );

    my $installableRoleJson = $installable->installableJson->{roles}->{$roleName};
    if( $installableRoleJson ) {
        my $appConfigItems = $installableRoleJson->{appconfigitems};
        if( $appConfigItems ) {
            my $codeDir   = $vars->getResolve( 'package.codedir' );
            my $dir       = $appConfig->vars()->getResolveOrNull( "appconfig.$roleName.dir", undef, 1 );
            my $itemIndex = 0;
            foreach my $appConfigItem ( @$appConfigItems ) {
                trace( 'Role::resume', $appConfig->appConfigId, $itemIndex );

                my $item = $self->instantiateAppConfigurationItem( $appConfigItem, $appConfig, $installable );
                if( $item ) {
                    debugAndSuspend(
                            'Resume',        $itemIndex,
                            'with role',      $roleName,
                            'of installable', $installable->packageName,
                            'at appconfig',   $appConfig->appConfigId );

                    $ret &= $item->resume( $codeDir, $dir, $vars );
                }
                ++$itemIndex;
            }
        }
    }
    return $ret;
}

##
# Make sure the site/virtual host is set up, or set it up
# $site: the Site to check or set up
# $doIt: if 1, setup; if 0, only check
# $triggers: triggers to be executed may be added to this hash
# return: success or fail
sub setupSiteOrCheck {
    my $self     = shift;
    my $site     = shift;
    my $doIt     = shift;
    my $triggers = shift;

    # no op on this level
    return 1;
}

##
# Do what is necessary to set up a named placeholder Site.
# $site: the Site for which a placeholder shall be set up
# $placeholderName: name of the placeholder
# $triggers: triggers to be executed may be added to this hash
# return: success or fail
sub setupPlaceholderSite {
    my $self            = shift;
    my $site            = shift;
    my $placeholderName = shift;
    my $triggers        = shift;

    # no op on this level
    return 1;
}

##
# Do what is necessary to suspend an already set-up Site
# $site: the Site
# $triggers: triggers to be executed may be added to this hash
# return: success or fail
sub suspendSite {
    my $self     = shift;
    my $site     = shift;
    my $triggers = shift;

    # no op on this level
    return 1;
}

##
# Do what is necessary to activate/resume an already set-up Site
# $site: the Site
# $triggers: triggers to be executed may be added to this hash
# return: success or fail
sub resumeSite {
    my $self     = shift;
    my $site     = shift;
    my $triggers = shift;

    # no op on this level
    return 1;
}

##
# Do what is necessary to remove a Site.
# $site: the Site
# $doIt: if 1, setup; if 0, only check
# $triggers: triggers to be executed may be added to this hash
# return: success or fail
sub removeSite {
    my $self     = shift;
    my $site     = shift;
    my $doIt     = shift;
    my $triggers = shift;

    # no op on this level
    return 1;
}

##
# Instantiate the right subclass of AppConfigurationItem.
# $json: the JSON fragment for the AppConfigurationItem
# $appConfig: the AppConfiguration that the AppConfigurationItem belongs to
# $installable: the Installable that the AppConfigurationItem belongs to
# return: instance of subclass of AppConfigurationItem, or undef
sub instantiateAppConfigurationItem {
    my $self        = shift;
    my $json        = shift;
    my $appConfig   = shift;
    my $installable = shift;

    my $ret;
    my $type = $json->{type};

    if( 'file' eq $type ) {
        $ret = UBOS::AppConfigurationItems::File->new( $json, $self, $appConfig, $installable );
    } elsif( 'directory' eq $type ) {
        $ret = UBOS::AppConfigurationItems::Directory->new( $json, $self, $appConfig, $installable );
    } elsif( 'directorytree' eq $type ) {
        $ret = UBOS::AppConfigurationItems::DirectoryTree->new( $json, $self, $appConfig, $installable );
    } elsif( 'symlink' eq $type ) {
        $ret = UBOS::AppConfigurationItems::Symlink->new( $json, $self, $appConfig, $installable );
    } elsif( 'perlscript' eq $type ) {
        $ret = UBOS::AppConfigurationItems::Perlscript->new( $json, $self, $appConfig, $installable );
    } elsif( 'sqlscript' eq $type ) {
        $ret = UBOS::AppConfigurationItems::Sqlscript->new( $json, $self, $appConfig, $installable );
    } elsif( 'systemd-service' eq $type ) {
        $ret = UBOS::AppConfigurationItems::SystemdService->new( $json, $self, $appConfig, $installable );
    } elsif( 'systemd-timer' eq $type ) {
        $ret = UBOS::AppConfigurationItems::SystemdTimer->new( $json, $self, $appConfig, $installable );
    } elsif( 'database' eq $type ) {
        $ret = UBOS::AppConfigurationItems::Database->new( $json, $self, $appConfig, $installable );
    } elsif( 'tcpport' eq $type ) {
        $ret = UBOS::AppConfigurationItems::TcpPort->new( $json, $self, $appConfig, $installable );
    } elsif( 'udpport' eq $type ) {
        $ret = UBOS::AppConfigurationItems::UdpPort->new( $json, $self, $appConfig, $installable );
    }
    unless( $ret ) {
        error( 'Unknown AppConfigurationItem type:', $type );
    }
    return $ret;
}

##
# Determine whether we already have letsencrypt certificates for this role for the given site
# $site: the Site
# return: 0 or 1
sub hasLetsEncryptCerts {
    my $self = shift;
    my $site = shift;

    return 0;
}

##
# If this role needs a letsencrypt certificate, obtain it.
# $site: the site that needs the certificate
sub obtainLetsEncryptCertificate {
    my $self = shift;
    my $site = shift;

    # on this level: nothing

    return 1;
}

##
# If this role needs (needed) a letsencrypt certificate, remove it.
# $site: the site that needs (needed) the certificate
sub removeLetsEncryptCertificate {
    my $self = shift;
    my $site = shift;

    # on this level: nothing

    return 1;
}

# === Manifest checking routines from here ===

##
# Check the part of an app manifest that deals with this role.
# $roleName: name of this role, passed for efficiency
# $installable: the installable whose manifest is being checked
# $jsonFragment: the JSON fragment that deals with this role
# $retentionBuckets: keep track of retention buckets, so there's no overlap
# $skipFilesystemChecks: if true, do not check the Site or Installable JSONs against the filesystem.
#       This is needed when reading Site JSON files in (old) backups
# $vars: the Variables object that knows about symbolic names and variables
sub checkAppManifestForRole {
    my $self                 = shift;
    my $roleName             = shift;
    my $installable          = shift;
    my $jsonFragment         = shift;
    my $retentionBuckets     = shift;
    my $skipFilesystemChecks = shift;
    my $vars                 = shift;

    $self->checkInstallableManifestForRole( $roleName, $installable, $jsonFragment, $retentionBuckets, $skipFilesystemChecks, $vars );
}

##
# Check the part of an accessory manifest that deals with this role.
# $roleName: name of this role, passed for efficiency
# $installable: the installable whose manifest is being checked
# $jsonFragment: the JSON fragment that deals with this role
# $retentionBuckets: keep track of retention buckets, so there's no overlap
# $skipFilesystemChecks: if true, do not check the Site or Installable JSONs against the filesystem.
#       This is needed when reading Site JSON files in (old) backups
# $vars: the Variables object that knows about symbolic names and variables
sub checkAccessoryManifestForRole {
    my $self                 = shift;
    my $roleName             = shift;
    my $installable          = shift;
    my $jsonFragment         = shift;
    my $retentionBuckets     = shift;
    my $skipFilesystemChecks = shift;
    my $vars                 = shift;

    $self->checkInstallableManifestForRole( $roleName, $installable, $jsonFragment, $retentionBuckets, $skipFilesystemChecks, $vars );
}

##
# Check the part of an app or accessory manifest that deals with this role.
# $roleName: name of this role, passed for efficiency
# $installable: the installable whose manifest is being checked
# $jsonFragment: the JSON fragment that deals with this role
# $retentionBuckets: keep track of retention buckets, so there's no overlap
# $skipFilesystemChecks: if true, do not check the Site or Installable JSONs against the filesystem.
#       This is needed when reading Site JSON files in (old) backups
# $vars: the Variables object that knows about symbolic names and variables
sub checkInstallableManifestForRole {
    my $self                 = shift;
    my $roleName             = shift;
    my $installable          = shift;
    my $jsonFragment         = shift;
    my $retentionBuckets     = shift;
    my $skipFilesystemChecks = shift;
    my $vars                 = shift;

    $installable->myFatal( "roles section implementation errror: role $roleName does not define checkInstallableManifestForRole, checkAppManifestForRole or checkAccessoryManifestForRole" );
}

##
# Check the part of a manifest that deals with this role and the generic 'depends'.
# $roleName: name of this role, passed for efficiency
# $installable: the installable whose manifest is being checked
# $jsonFragment: the JSON fragment that deals with this role
# $vars: the Variables object that knows about symbolic names and variables
sub checkManifestForRoleGenericDepends {
    my $self         = shift;
    my $roleName     = shift;
    my $installable  = shift;
    my $jsonFragment = shift;
    my $vars         = shift;

    if( exists( $jsonFragment->{depends} )) {
        unless( ref( $jsonFragment->{depends} ) eq 'ARRAY' ) {
            $installable->myFatal( "roles section: role $roleName: depends is not an array" );
        }
        my $dependsIndex = 0;
        foreach my $depends ( @{$jsonFragment->{depends}} ) {
            if( ref( $depends )) {
                $installable->myFatal( "roles section: role $roleName: depends[$dependsIndex] must be string" );
            }
            unless( $depends =~ m!^[-_a-z0-9]+$! ) {
                $installable->myFatal( "roles section: role $roleName: depends[$dependsIndex] invalid: $depends" );
            }
            ++$dependsIndex;
        }
    }
}

##
# Check the part of a manifest that deals with this role and the generic 'appconfigitems'.
# $roleName: name of this role, passed for efficiency
# $installable: the installable whose manifest is being checked
# $jsonFragment: the JSON fragment that deals with this role
# $allowedTypes: hash of allowed types
# $retentionBuckets: keep track of retention buckets, so there's no overlap
# $skipFilesystemChecks: if true, do not check the Site or Installable JSONs against the filesystem.
#       This is needed when reading Site JSON files in (old) backups
# $vars: the Variables object that knows about symbolic names and variables
sub checkManifestForRoleGenericAppConfigItems {
    my $self                 = shift;
    my $roleName             = shift;
    my $installable          = shift;
    my $jsonFragment         = shift;
    my $allowedTypes         = shift;
    my $retentionBuckets     = shift;
    my $skipFilesystemChecks = shift;
    my $vars                 = shift;

    if( exists( $jsonFragment->{appconfigitems} )) {
        unless( ref( $jsonFragment->{appconfigitems} ) eq 'ARRAY' ) {
            $installable->myFatal( "roles section: role $roleName: not an array" );
        }
        my $codeDir = $vars->getResolve( 'package.codedir' );

        my %databaseNames = ();

        my $appConfigIndex = 0;
        foreach my $appConfigItem ( @{$jsonFragment->{appconfigitems}} ) {
            if( ref( $appConfigItem->{type} )) {
                $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'type' must be string" );
            }
            unless( $allowedTypes->{ $appConfigItem->{type}} ) {
                $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] has unknown or disallowed type: " . $appConfigItem->{type}
                                           . ". Allowed types are: " . join( ', ', sort keys %$allowedTypes ) );
            }

            if( $appConfigItem->{type} eq 'perlscript' ) {
                # perlscript only gets to have source, not template
                unless( $appConfigItem->{source} ) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type " . $appConfigItem->{type} . ": must specify source" );
                }
                if( ref( $appConfigItem->{source} )) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type " . $appConfigItem->{type} . ": field 'name' must be string" );
                }
                if( !$skipFilesystemChecks && !UBOS::Installable::validFilename( $codeDir, $vars->replaceVariables( $appConfigItem->{source} ))) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type " . $appConfigItem->{type} . " has invalid source: " . $appConfigItem->{source} );
                }
                if( exists( $appConfigItem->{name} ) && ref( $appConfigItem->{name} )) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'name' must be string" );
                }
                if( $appConfigItem->{names} ) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type " . $appConfigItem->{type} . ": names not permitted for type " . $appConfigItem->{type} );
                }
            } elsif( $appConfigItem->{type} eq 'sqlscript' ) {
                # sqlscript gets to have source or template

                if( exists( $appConfigItem->{name} ) && ref( $appConfigItem->{name} )) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript': field 'name' must be string" );
                }
                if( $appConfigItem->{names} ) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript': names not permitted for type " . $appConfigItem->{type} );
                }
                if( $appConfigItem->{source} ) {
                    if( $appConfigItem->{template} ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript': specify source or template, not both" );
                    }
                    if( ref( $appConfigItem->{source} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript': field 'source' must be string" );
                    }
                    if( !$skipFilesystemChecks && !UBOS::Installable::validFilename( $codeDir, $vars->replaceVariables( $appConfigItem->{source} ))) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript' has invalid source: " . $appConfigItem->{source} );
                    }
                } elsif( $appConfigItem->{template} ) {
                    unless( $appConfigItem->{templatelang} ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript': if specifying template, must specify templatelang as well" );
                    }
                    if( ref( $appConfigItem->{template} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript': field 'template' must be string" );
                    }
                    if( !$skipFilesystemChecks && !UBOS::Installable::validFilename( $codeDir, $vars->replaceVariables( $appConfigItem->{template} ))) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript' has invalid template: " . $appConfigItem->{template} );
                    }
                    if( ref( $appConfigItem->{templatelang} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript': field 'templatelang' must be string" );
                    }
                    unless( $appConfigItem->{templatelang} =~ m!^(varsubst|perlscript)$! ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'sqlscript': invalid templatelang: " . $appConfigItem->{templatelang} );
                    }
                } else {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': must specify source or template" );
                }

            } elsif( $appConfigItem->{type} eq 'systemd-service' || $appConfigItem->{type} eq 'systemd-timer' ) {
                if( defined( $appConfigItem->{names} )) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: specify name; names not allowed" );
                }
                if( !defined( $appConfigItem->{name} ) || ref( $appConfigItem->{name} || !$appConfigItem->{name} )) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'name' must be string" );
                }

            } elsif( $appConfigItem->{type} eq 'tcpport' || $appConfigItem->{type} eq 'udpport' ) {
                if( defined( $appConfigItem->{names} )) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: specify name; names not allowed" );
                }
                if( !defined( $appConfigItem->{name} ) || ref( $appConfigItem->{name} || !$appConfigItem->{name} )) {
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'name' must be string" );
                }

            } else {
                my @names = ();
                if( defined( $appConfigItem->{name} )) {
                    if( $appConfigItem->{names} ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: specify name or names, not both" );
                    }
                    if( ref( $appConfigItem->{name} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'name' must be string" );
                    }
                    # file does not exist yet
                    push @names, $appConfigItem->{name};

                } else {
                    unless( $appConfigItem->{names} ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: must specify name or names" );
                    }
                    unless( ref( $appConfigItem->{names} ) eq 'ARRAY' ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: names must be an array" );
                    }
                    my $namesIndex = 0;
                    foreach my $name ( @{$appConfigItem->{names}} ) {
                        if( ref( $name )) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: names[$namesIndex] must be string" );
                        }
                        # file does not exist yet
                        push @names, $name;
                        ++$namesIndex;
                    }
                    unless( $namesIndex > 0 ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: must specify name or names" );
                    }
                }

                if( $appConfigItem->{type} eq 'file' ) {
                    if( $appConfigItem->{source} ) {
                        if( $appConfigItem->{template} ) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': specify source or template, not both" );
                        }
                        if( ref( $appConfigItem->{source} )) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': field 'source' must be string" );
                        }
                        foreach my $name ( @names ) {
                            unless( UBOS::Installable::validFilename( $codeDir, $vars->replaceVariables( $appConfigItem->{source} ), $name )) {
                                $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': invalid source: " . $appConfigItem->{source} . " for name $name" );
                            }
                        }
                    } elsif( $appConfigItem->{template} ) {
                        unless( $appConfigItem->{templatelang} ) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': if specifying template, must specify templatelang as well" );
                        }
                        if( ref( $appConfigItem->{template} )) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': field 'template' must be string" );
                        }
                        unless( $skipFilesystemChecks ) {
                            foreach my $name ( @names ) {
                                unless( UBOS::Installable::validFilename( $codeDir, $vars->replaceVariables( $appConfigItem->{template} ), $name )) {
                                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': invalid template: " . $appConfigItem->{template} . " for name $name" );
                                }
                            }
                        }
                        if( ref( $appConfigItem->{templatelang} )) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': field 'templatelang' must be string" );
                        }
                        unless( $appConfigItem->{templatelang} =~ m!^(varsubst|perlscript)$! ) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': invalid templatelang: " . $appConfigItem->{templatelang} );
                        }
                    } else {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'file': must specify source or template" );
                    }

                } elsif( $appConfigItem->{type} eq 'directory' ) {

                } elsif( $appConfigItem->{type} eq 'directorytree' ) {
                    unless( $appConfigItem->{source} ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'directorytree': must specify source" );
                    }
                    if( ref( $appConfigItem->{source} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'directorytree': field 'source' must be string" );
                    }
                    unless( $skipFilesystemChecks ) {
                        foreach my $name ( @names ) {
                            unless( UBOS::Installable::validFilename( $codeDir, $vars->replaceVariables( $appConfigItem->{source} ), $name )) {
                                $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'directorytree': invalid source: " . $appConfigItem->{source} . " for name $name" );
                            }
                        }
                    }

                } elsif( $appConfigItem->{type} eq 'symlink' ) {
                    unless( $appConfigItem->{source} ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'symlink': must specify source" );
                    }
                    if( ref( $appConfigItem->{source} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'symlink': field 'source' must be string" );
                    }
                    unless( $appConfigItem->{source} =~ m!\$\{.*\}! ) {
                        # Symlinks get to have variables in their sources
                        unless( $skipFilesystemChecks ) {
                            foreach my $name ( @names ) {
                                unless( $name  && UBOS::Installable::validFilename( $codeDir, $vars->replaceVariables( $appConfigItem->{source} ), $name )) {
                                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] of type 'symlink': invalid source: " . $appConfigItem->{source} . " for name $name" );
                                }
                            }
                        }
                    }

                } elsif( $appConfigItem->{type} =~ m!database$! ) {
                    # no op

                    if( $databaseNames{$appConfigItem->{name}} ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] has non-unique symbolic database name" );
                        $databaseNames{$appConfigItem->{name}} = 1;
                    }

                    if( $appConfigItem->{privileges} ) {
                        if( ref( $appConfigItem->{privileges} )) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'privileges' must be string" );
                        }
                    } else {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'privileges' must be given" );
                    }

                } else { # perlscript and sqlscript handled above
                    $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] has unknown type (1): " . $appConfigItem->{type}
                                              . ". Allowed types are: " . join( ', ', sort keys %$allowedTypes ) );
                }

                if( $appConfigItem->{uname} ) {
                    if( ref( $appConfigItem->{uname} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'uname' must be string" );
                    }
                    unless( $vars->replaceVariables( $appConfigItem->{uname} ) =~ m!^[-a-z0-9]+$! ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: invalid uname: " . $appConfigItem->{uname} );
                    }
                    unless( $appConfigItem->{gname} ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'gname' must be given is 'uname' is given." );
                    }
                }
                if( $appConfigItem->{gname} ) {
                    if( ref( $appConfigItem->{gname} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'gname' must be string" );
                    }
                    unless( $vars->replaceVariables( $appConfigItem->{gname} ) =~ m!^[-a-z0-9]+$! ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: invalid gname: " . $appConfigItem->{gname} );
                    }
                    unless( $appConfigItem->{uname} ) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'uname' must be given is 'gname' is given." );
                    }
                }
                if( $appConfigItem->{type} eq 'directorytree' || $appConfigItem->{type} eq 'directory' ) {
                    foreach my $f ( 'filepermissions', 'dirpermissions' ) {
                        if( defined( $appConfigItem->{$f} )) {
                            if( ref( $appConfigItem->{$f} )) {
                                $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field '$f' must be string (octal)" );
                            }
                            unless( $vars->replaceVariables( $appConfigItem->{$f} ) =~ m!^(preserve|[0-7]{3,4})$! ) {
                                $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: invalid $f: " . $appConfigItem->{$f} );
                            }
                        }
                    }
                    if( defined( $appConfigItem->{permissions} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: use fields 'filepermissions' and 'dirpermissions' instead of 'permissions'." );
                    }
                } else {
                    if( defined( $appConfigItem->{permissions} )) {
                        if( ref( $appConfigItem->{permissions} )) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'permissions' must be string (octal)" );
                        }
                        unless( $vars->replaceVariables( $appConfigItem->{permissions} ) =~ m!^(preserve|[0-7]{3,4})$! ) {
                            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: invalid permissions (need octal, no leading zero): " . $appConfigItem->{permissions} );
                        }
                    }
                    if( defined( $appConfigItem->{filepermissions} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: use field 'permissions' instead of 'filepermissions'." );
                    }
                    if( defined( $appConfigItem->{dirpermissions} )) {
                        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: use field 'permissions' instead of 'dirpermissions'." );
                    }
                }

                _checkRetention( $installable, $appConfigItem, $roleName, $appConfigIndex, $retentionBuckets );
            }
            ++$appConfigIndex;
        }
    }
}

##
# Check the part of a manifest that deals with this role and the generic 'triggersactivate'.
# $roleName: name of this role, passed for efficiency
# $installable: the installable whose manifest is being checked
# $jsonFragment: the JSON fragment that deals with this role
# $vars: the Variables object that knows about symbolic names and variables
sub checkManifestForRoleGenericTriggersActivate {
    my $self         = shift;
    my $roleName     = shift;
    my $installable  = shift;
    my $jsonFragment = shift;
    my $allowedTypes = shift;
    my $vars         = shift;

    if( exists( $jsonFragment->{triggersactivate} )) {
        unless( ref( $jsonFragment->{triggersactivate} ) eq 'ARRAY' ) {
            $installable->myFatal( "roles section: role $roleName: triggersactivate: not an array" );
        }
        my $triggersIndex = 0;
        my %triggers = ();
        foreach my $triggersJson ( @{$jsonFragment->{triggersactivate}} ) {
            if( ref( $triggersJson )) {
                $installable->myFatal( "roles section: role $roleName: triggersactivate[$triggersIndex]: not an array" );
            }
            unless( $triggersJson =~ m/^[a-z][-a-z0-9]*$/ ) {
                $installable->myFatal( "roles section: role $roleName: triggersactivate[$triggersIndex]: invalid trigger name: $triggersJson" );
            }
            if( $triggers{$triggersJson} ) {
                $installable->myFatal( "roles section: role $roleName: triggersactivate[$triggersIndex] is not unique: $triggersJson" );
                $triggers{$triggersJson} = 1;
            }
            ++$triggersIndex;
        }
    }
}

##
# Check the part of a manifest that deals with this role and the generic 'installers',
# 'uninstallers' and 'upgraders'.
# $roleName: name of this role, passed for efficiency
# $installable: the installable whose manifest is being checked
# $jsonFragment: the JSON fragment that deals with this role
# $allowedTypes: hash of allowed types
# $vars: the Variables object that knows about symbolic names and variables
sub checkManifestForRoleGenericInstallersEtc {
    my $self         = shift;
    my $roleName     = shift;
    my $installable  = shift;
    my $jsonFragment = shift;
    my $allowedTypes = shift;
    my $vars         = shift;

    my $codeDir = $vars->getResolve( 'package.codedir' );

    foreach my $postInstallCategory ( 'installers', 'uninstallers', 'upgraders' ) {
        unless( defined( $jsonFragment->{$postInstallCategory} )) {
            next;
        }
        unless( ref( $jsonFragment->{$postInstallCategory} ) eq 'ARRAY' ) {
            $installable->myFatal( "$postInstallCategory section: not an array" );
        }
        my $itemsIndex = 0;
        foreach my $item ( @{$jsonFragment->{$postInstallCategory}} ) {
            if( ref( $item->{type} )) {
                $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex]: field 'type' must be string" );
            }
            unless( $allowedTypes->{ $item->{type}} ) {
                $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex]: unknown type: " . $item->{type} );
            }
            if( $item->{source} ) {
                if( $item->{template} ) {
                    $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex] of type '" . $item->{type} . "': specify source or template, not both" );
                }
                if( ref( $item->{source} )) {
                    $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex] of type '" . $item->{type} . "': field 'source' must be string" );
                }
                unless( UBOS::Installable::validFilename( $codeDir, $vars->replaceVariables( $item->{source} ))) {
                    $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex]: invalid source" );
                }
            } else {
                unless( $item->{template} ) {
                    $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex] of type '" . $item->{type} . "': specify source or template" );
                }
                unless( UBOS::Installable::validFilename( $codeDir, $vars->replaceVariables( $item->{template} ))) {
                    $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex]: invalid template" );
                }
                if( ref( $item->{templatelang} )) {
                    $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex] of type '" . $item->{type} . "': field 'templatelang' must be string" );
                }
                unless( $item->{templatelang} =~ m!^(varsubst|perlscript)$! ) {
                    $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . " [$itemsIndex] of type '" . $item->{type} . "': invalid templatelang: " . $item->{templatelang} );
                }
            }
            if( $item->{type} eq 'sqlscript' ) { # This does not hurt here even for non-sql roles
                unless( $item->{name} ) {
                    $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex]: must specify 'name'" );
                }
                if( ref( $item->{name} )) {
                    $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex]: invalid 'name'" );
                }
                if( $item->{delimiter} ) {
                    if( ref( $item->{delimiter} )) {
                        $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex]: invalid delimiter" );
                    }
                    if( $item->{delimiter} !~ m!^[;|\$]$! ) {
                        $installable->myFatal( "roles section: role $roleName: $postInstallCategory" . "[$itemsIndex]: invalid delimiter" );
                    }
                }
            }

            ++$itemsIndex;
        }
    }
}

##
# Helper method to check retentionpolicy.
# $installable: the installable whose manifest is being checked
# $appConfigItem: the AppConfigItem that may have a retentionpolicy
# $roleName: name of the currently examined role
# $appConfigIndex: index if the currently examined AppConfigItem in its role section
# $retentionBuckets: hash of retentionbuckets specified so far
sub _checkRetention {
    my $installable      = shift;
    my $appConfigItem    = shift;
    my $roleName         = shift;
    my $appConfigIndex   = shift;
    my $retentionBuckets = shift;

    if( exists( $appConfigItem->{retentionpolicy} )) {
        if( ref( $appConfigItem->{retentionpolicy} )) {
            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'retentionpolicy' must be string" );
        }
        if( $appConfigItem->{retentionpolicy} ne 'keep' ) {
            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex] has unknown value for field 'retentionpolicy': " . $appConfigItem->{retentionpolicy} );
        }
        unless( exists( $appConfigItem->{retentionbucket} )) {
            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: if specifying 'retentionpolicy', also specify 'retentionbucket'" );
        }
        if( ref( $appConfigItem->{retentionbucket} )) {
            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'retentionbucket' must be string" );
        }
        if( $retentionBuckets->{$appConfigItem->{retentionbucket}} ) {
            $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: field 'retentionbucket' must be unique: " . $appConfigItem->{retentionbucket} );
        }
        $retentionBuckets->{$appConfigItem->{retentionbucket}} = 1;

    } elsif( exists( $appConfigItem->{retentionbucket} )) {
        $installable->myFatal( "roles section: role $roleName: appconfigitem[$appConfigIndex]: if specifying 'retentionbucket', also specify 'retentionpolicy'" );
    }
}

1;
