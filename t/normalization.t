use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempdir);
use Test::More;

BEGIN {
	package Slim::Player::ProtocolHandlers;
	sub registerHandler { }
	$INC{'Slim/Player/ProtocolHandlers.pm'} = __FILE__;

	package Slim::Utils::Log;
	sub import {
		no strict 'refs';
		*{ caller() . '::logger' } = sub { bless {}, 'TestLogger' };
	}
	$INC{'Slim/Utils/Log.pm'} = __FILE__;

	package TestLogger;
	sub debug { }
	sub error { }
	sub info { }

	package Slim::Utils::Strings;
	sub import {
		no strict 'refs';
		*{ caller() . '::cstring' } = sub { $_[1] };
	}
	$INC{'Slim/Utils/Strings.pm'} = __FILE__;

	package Plugins::SpotifySoloist::Plugin;
	sub directStreamInfoForUrl { return }
}

require './ProtocolHandler.pm';
require './SoloistPrefs.pm';

is(
	Plugins::SpotifySoloist::ProtocolHandler->trackGain(
		undef,
		'soloist://player-0/soloist.wav',
	),
	0,
	'soloist streams override LMS remote replay gain with unity gain',
);
is(
	Plugins::SpotifySoloist::ProtocolHandler->isRepeatingStream(),
	1,
	'soloist streams identify as continuous so DSTM does not queue a next song',
);

is(
	Plugins::SpotifySoloist::SoloistPrefs::normalizationForPlayer( undef, 'player-a' ),
	1,
	'missing normalization preferences preserve the enabled default',
);
is(
	Plugins::SpotifySoloist::SoloistPrefs::normalizationForPlayer(
		{ 'player-a' => 0, 'player-b' => 1 },
		'player-a',
	),
	0,
	'normalization resolves off for the selected player',
);
is(
	Plugins::SpotifySoloist::SoloistPrefs::normalizationForPlayer(
		{ 'player-a' => 0, 'player-b' => 1 },
		'player-b',
	),
	1,
	'normalization resolves on independently for another player',
);

sub write_file {
	my ( $path, $content ) = @_;
	open my $fh, '>:raw', $path or die "write $path: $!";
	print {$fh} $content;
	close $fh;
}

sub read_file {
	my ($path) = @_;
	open my $fh, '<:raw', $path or die "read $path: $!";
	local $/;
	return <$fh>;
}

my $dir = tempdir( CLEANUP => 1 );
my $settings = catdir( $dir, 'settings' );
my $global = catfile( $settings, 'prefs' );

my $written = Plugins::SpotifySoloist::SoloistPrefs::writeNormalization( $dir, 1 );
is_deeply( $written, [$global], 'creates the global prefs when settings are missing' );
is( read_file($global), "audio.normalize_v2=true\n", 'writes normalization on' );

write_file( $global, "unrelated.key=kept\naudio.normalize_v2=true\naudio.normalize_v2=false\n" );
Plugins::SpotifySoloist::SoloistPrefs::writeNormalization( $dir, 0 );
is(
	read_file($global),
	"unrelated.key=kept\naudio.normalize_v2=false\n",
	'replaces stale normalization keys and preserves unrelated settings',
);

my $aliceDir = catdir( $settings, 'Users', 'alice' );
my $bobDir = catdir( $settings, 'Users', 'bob' );
make_path( $aliceDir, $bobDir );
my $alicePrefs = catfile( $aliceDir, 'prefs' );
write_file( $alicePrefs, "user.setting=yes\naudio.normalize_v2=false\n" );

$written = Plugins::SpotifySoloist::SoloistPrefs::writeNormalization( $dir, 1 );
is_deeply(
	$written,
	[ $global, $alicePrefs ],
	'updates existing per-user prefs without inventing missing user prefs',
);
is(
	read_file($alicePrefs),
	"user.setting=yes\naudio.normalize_v2=true\n",
	'updates the per-user override while preserving user settings',
);
ok( !-e catfile( $bobDir, 'prefs' ), 'leaves a user directory without prefs untouched' );

done_testing;
