#
# A n empty volume that allocates space for the MBR.
#
# Copyright (C) 2014 and later, Indie Computing Corp. All rights reserved. License: see package.
#

use strict;
use warnings;

package UBOS::Install::Volumes::MbrVolume;

use base qw( UBOS::Install::AbstractVolume );
use fields qw();

use UBOS::Logging;

##
# Constructor
# %pars: parameters with the same names as member variables
sub new {
    my $self = shift;
    my %pars = @_;

    unless( ref( $self )) {
        $self = fields::new( $self );
    }
    # set defaults for this class here
    $self->{label}       = 'mbr';
    $self->{mountPoint}  = '';
    $self->{fs}          = '';
    $self->{mkfsFlags}   = '';
    $self->{partedFs}    = '';
    $self->{partedFlags} = [ qw( bios_grub ) ];
    $self->{size}        = 4 * 1024 * 1024; # 4 MB

    $self->SUPER::new( %pars );

    return $self;
}

1;


