package Plugins::SpotifySoloist::SoloistPrefs;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempfile);

sub writeNormalization {
	my ( $dataDir, $enabled ) = @_;
	die "Soloist data directory is required\n" unless defined $dataDir && length $dataDir;

	my $settingsDir = catdir( $dataDir, 'settings' );
	make_path($settingsDir) unless -d $settingsDir;

	my @paths = ( catfile( $settingsDir, 'prefs' ) );
	my $usersDir = catdir( $settingsDir, 'Users' );
	if ( -d $usersDir ) {
		opendir my $dh, $usersDir
			or die "couldn't read Soloist user settings directory '$usersDir': $!\n";
		for my $entry ( sort readdir $dh ) {
			next if $entry eq '.' || $entry eq '..';
			my $path = catfile( $usersDir, $entry, 'prefs' );
			push @paths, $path if -f $path;
		}
		closedir $dh;
	}

	_writePrefs( $_, $enabled ? 'true' : 'false' ) for @paths;
	return \@paths;
}

sub normalizationForPlayer {
	my ( $values, $playerId ) = @_;
	return 1 unless ref $values eq 'HASH' && exists $values->{$playerId};
	return $values->{$playerId} ? 1 : 0;
}

sub _writePrefs {
	my ( $path, $value ) = @_;
	my $content = '';
	my $mode;

	if ( -e $path ) {
		open my $in, '<:raw', $path
			or die "couldn't read Soloist prefs '$path': $!\n";
		local $/;
		$content = <$in>;
		close $in
			or die "couldn't close Soloist prefs '$path' after reading: $!\n";
		$mode = ( stat $path )[2] & 07777;
	}

	my $newline = $content =~ /\r\n/ ? "\r\n" : "\n";
	my @lines = split /\r?\n/, $content, -1;
	@lines = grep { $_ !~ /^\s*audio\.normalize_v2\s*=/ } @lines;
	pop @lines while @lines && $lines[-1] eq '';
	push @lines, "audio.normalize_v2=$value";
	my $updated = join( $newline, @lines ) . $newline;

	my ( $out, $tmp ) = tempfile( '.prefs-XXXXXX', DIR => dirname($path), UNLINK => 0 );
	my $error;
	eval {
		binmode($out);
		print {$out} $updated
			or die "couldn't write temporary Soloist prefs '$tmp': $!\n";
		if ( defined $mode ) {
			chmod $mode, $tmp
				or die "couldn't preserve permissions on temporary Soloist prefs '$tmp': $!\n";
		}
		close $out
			or die "couldn't close temporary Soloist prefs '$tmp': $!\n";
		rename $tmp, $path
			or die "couldn't atomically replace Soloist prefs '$path': $!\n";
	};
	$error = $@;
	if ($error) {
		close $out;
		unlink $tmp;
		die $error;
	}
}

1;
