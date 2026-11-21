use strict;
use warnings;

use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	local $/;
	return <$fh>;
}

my $types = slurp('custom-types.conf');
my $convert = slurp('custom-convert.conf');
my $bridge = slurp('Bin/soloist-bridge.sh');
my $settings = slurp('Settings.pm');
my $html = slurp('HTML/EN/plugins/SpotifySoloist/settings/basic.html');

like( $types, qr/^s32p\s+-\s+audio\/x-soloist-s32-pcm\s+audio$/m, 'registers the S32-to-PCM source type' );
like( $types, qr/^s32f\s+-\s+audio\/x-soloist-s32-flac\s+audio$/m, 'registers the S32-to-FLAC source type' );
for my $rate (qw(96 128 160 192 256 320)) {
	like( $types, qr/^s32m\Q$rate\E\s+-\s+audio\/x-soloist-s32-mp3-\Q$rate\E\s+audio$/m, "registers the ${rate}k S32-to-MP3 source type" );
	like( $convert, qr/^s32m\Q$rate\E\s+mp3\s+\*\s+\*.*?^\s*\[ffmpeg\].*?-b:a \Q$rate\Ek /ms, "hard-codes the selected ${rate}k MP3 bitrate" );
}

for my $rule (qw(s32p-pcm s32f-flc)) {
	my ($source, $dest) = split /-/, $rule;
	like( $convert, qr/^\Q$source\E\s+\Q$dest\E\s+\*\s+\*$/m, "defines $source to $dest conversion" );
}
is( () = $convert =~ /\[ffmpeg\]/g, 8, 'all final formats use LMS dependency-checked ffmpeg rules' );
unlike( $bridge, qr/ffmpeg/i, 'bridge never invokes or configures ffmpeg' );
unlike( $bridge, qr/SOLOIST_SHIM_(?:FORMAT|MODE)|SOLOIST_PCM_SHIM_FIFO/, 'bridge exposes no obsolete shim mode or intermediate FIFO' );
unlike( $settings . $html, qr/playerLiveRing|liveRing\./, 'settings expose no compatibility-mode preference' );

done_testing;
