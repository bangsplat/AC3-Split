#!/usr/bin/perl
use strict;	# Enforce some good programming rules

use File::Find;

#####
#
# splitAC3.pl
#	version		0.92
# 	created 	2014-12-10
# 	modified	2015-02-13
# 	author		Theron Trowbridge
#
# based on parseAC3.pl
#
# description
# 
# 
# syntax
# 
# 
# output
#
#
#####


# constants

my $AC3_SYNC_WORD = pack( 'H[4]', "0b77" );
my $verbosity = 0;

# variables

my ( $input_file, $errors, $warnings, $extension, $result, $file_size );
my ( $byte, $bitfield );
my ( $syncinfo, $syncword, $crc1, $fscod, $frmsizecod );
my ( $bitrate_in_kbps, $sampling_rate_in_khz, $num_words_in_syncframe );
my ( $syncframe_size, $total_syncframes, $total_seconds );
my ( $byte_pointer, $bit_pointer );
my $bsi;
my ( $bsid, $bsmod, $acmod, $cmixlev, $surmixlev, $dsurmod, $lfeon );
my ( $bsid_bitfield, $bsmod_bitfield, $acmod_bitfield );
my ( $cmixlev_bitfield, $surmixlev_bitfield, $dsurmod_bitfield );
my ( $dialnorm_bitfield, $compre_bitfield, $compr_bitfield );
my ( $langcode_bitfield, $langcod_bitfield );
my ( $audprodie_bitfield, $mixlev_bitfield, $roomtyp_bitfield );
my ( $dialnorm, $compre, $compr, $langcode, $langcod, $audprodie, $mixlev, $roomtyp );
my ( $dialnorm2_bitfield, $compr2e_bitfield, $compr2_bitfield, $langcod2e_bitfield );
my ( $langcod2_bitfield, $audprodi2e_bitfield, $mixlev2_bitfield, $roomtyp2_bitfield );
my ( $dialnorm2, $compr2e, $compr2, $langcod2e, $langcod2, $audprodi2e, $mixlev2, $roomtyp2 );
my ( $compr_dB, $compr_dB_rounded, $compr2_dB, $compr2_dB_rounded );
my ( $copyrightb, $origbs, $timecod1e, $timecod1_bitfield, $timecod1 );
my ( $timecod2e, $timecod2_bitfield, $timecod2, $addbsie );
my ( $addbsil_bitfield, $addbsil, $addbsi );

my $buffer;

my $previous_frame_acmod;
my $current_frame_acmod;
my $file_basename;
my $segment_number;
my $current_filename;

my ( $previous_sample_rate, $current_sample_rate );

my $analyze_only = 0;



# main

## quick an dirty
## only one file, no globs
$input_file = @ARGV[0];

if ( @ARGV[1] ne undef ) {
	$analyze_only = 1;
}

if ( $input_file eq undef ) {
	find( \&findAC3, "." );
	# this will attempt to find a file ending in .ac3
}

$file_basename = $input_file;
$file_basename =~ s/\.ac3$//;

### it would be nice to find any/all .ac3 files if no @ARGV[0]

# open the file
$result = open( INPUT_FILE, "<", $input_file );
if ( $result eq undef ) {
	print "$input_file: error: coud not open file $!\n";
	exit;
}

binmode( INPUT_FILE );			# binary file
$file_size = -s INPUT_FILE;		# get size of input file

## assume there is no preamble

# read the first 5 bytes, which should be the sync info
$result = read( INPUT_FILE, $syncinfo, 5 );
if ( $result == undef ) {
	print "$input_file: error: could not read syncinfo()\n";
	close( INPUT_FILE );
	exit;
}

# parse syncinfo()
$syncword = unpack( 'H[4]', substr( $syncinfo, 0, 2 ) );
$crc1 = unpack( 'H[4]', substr( $syncinfo, 2, 2 ) );

## note fscod and frmsizecod are a packed bitfield
$bitfield = unpack( "B[8]", substr( $syncinfo, 4, 1 ) );
$fscod = binary_to_decimal( substr( $bitfield, 0, 2 ) );
$frmsizecod = binary_to_decimal( substr( $bitfield, 2, 6 ) );

$bitrate_in_kbps = getBitrate( $frmsizecod );
$sampling_rate_in_khz = getSamplingRate( $fscod );

$num_words_in_syncframe = evalFrmsizecodValue( $frmsizecod, $fscod );
$syncframe_size = $num_words_in_syncframe * 2;
$total_syncframes = $file_size / $syncframe_size;
$total_seconds = $total_syncframes / 31.25;

# stash the sampling rate for analysis
$previous_sample_rate = $current_sample_rate = $sampling_rate_in_khz;

if ( $verbosity > 0 ) {
	print "sync frames are: $syncframe_size bytes\n";
	print "stream is $total_syncframes frames (31.25 fps) long\n";
}

# rewind file
seek( INPUT_FILE, 0, 0 );

$current_frame_acmod = "";
$segment_number = 0;	# no current output file

for ( my $i = 0; $i < $total_syncframes; $i++ ) {
	# reset pointers
	$byte_pointer = 0;
	$bit_pointer = 0;
	
	# read $syncframe_size bytes
	$result = read( INPUT_FILE, $buffer, $syncframe_size );
	$syncword = unpack( 'H[4]', substr( $buffer, 0, 2 ) );
	$byte_pointer += 2;
#	print "syncframe $i syncword: $syncword\n";
	
#	# we don't really care about the rest of the sync info, so skip it
#	$byte_pointer = 5;

	# well, maybe we do care :)
	
	# $byte_pointer is now pointing at crc1 (2 bytes)
	# skip ahead to fscod/frmsizecod
	$byte_pointer += 2;
	
	$bitfield = unpack( "B[8]", substr( $buffer, $byte_pointer, 1 ) );
	$fscod = binary_to_decimal( substr( $bitfield, 0, 2 ) );
	$frmsizecod = binary_to_decimal( substr( $bitfield, 2, 6 ) );
	$current_sample_rate = getSamplingRate( $fscod );
	
#	print "syncframe $i sampling rate: $current_sample_rate\n";
	
	if ( $current_sample_rate != $previous_sample_rate ) {
		print "ERROR - syncrframe $i has a different sampling rate: $current_sample_rate\n";
	}
	
	# move on to bsid
	$byte_pointer++;
	
	# decode bsid and bsmod, which is the next byte
	$bitfield = unpack( "B[8]", substr( $buffer, $byte_pointer, 1 ) );
	$byte_pointer += 1;
	
	$bsid_bitfield = substr( $bitfield, 0, 5 );
	$bsid = binary_to_decimal( $bsid_bitfield );
	$bsmod_bitfield = substr( $bitfield, 5, 3 );
	$bsmod = binary_to_decimal( $bsmod_bitfield );
	
	# bsmod meaning is affected by acmod, which is the next three bits
	# what comes after that can vary based on values of acmod
	# one byte should be enough to cover all the possibilities
	
	# read next byte
	$bitfield = unpack( "B[8]", substr( $buffer, $byte_pointer, 1 ) );
	$byte_pointer += 1;
	
	$acmod_bitfield = substr( $bitfield, $bit_pointer, 3 );
	$acmod = binary_to_decimal( $acmod_bitfield );
	$bit_pointer += 3;
	
	# remember what the previous frame's audio channel configuration was
	$previous_frame_acmod = $current_frame_acmod;
	
	# compare the current frame's audio channel configuration to the last frame's
	$current_frame_acmod = $acmod;
	if ( $current_frame_acmod ne $previous_frame_acmod ) {
		# it has changed
		# close the current file
		# 	make sure we aren't at the very start of the file first
		if ( !$analyze_only ) {
			if ( $segment_number > 0 ) { close( OUTPUT_FILE ); }
		}
		# open a new segment file
		$segment_number++;
		$current_filename = $file_basename . "_$segment_number" . ".ac3";
		if ( $verbosity > 0 ) {
			print "$current_filename\n";
		}
		if ( !$analyze_only ) {
			open( OUTPUT_FILE, '>', $current_filename );
			binmode( OUTPUT_FILE );
		}
	}
	
	# write this frame to the current output file
	if ( !$analyze_only ) {
		print OUTPUT_FILE $buffer;
	}
	
	if ( $verbosity > 0 ) {
		print "syncframe $i acmod: $acmod\n";
	}

}
### THIS WILL BREAK IF SYNCFRAME SIZE CHANGES
### but I think it's a safe risk for now

# when we're all done, report the number of segments
print "$segment_number\n";

close( INPUT_FILE );
close( OUTPUT_FILE );


# subroutines


sub findAC3 {
	if ( /.ac3$/i && ( $File::Find::dir eq "." ) ) {
		$input_file = $File::Find::name;
	}
}


#####
#
# getBitrate()
#
# takes value (in decimal form) of frmsizecod
# does lookup in ATSC A/52B Table 5.18
# returns bitrate (in kbps)
#
#####
sub getBitrate {
	my @bitrate_table = (32,32,40,40,48,48,56,56,64,64,80,80,96,96,112,112,128,128,160,160,192,192,224,224,256,256,320,320,384,384,448,448,512,512,576,576,640,640);
	return( $bitrate_table[$_[0]] );
}

#####
#
# getSamplingRate()
#
# takes value (in decimal form) of fscod
# does lookup in ATSC A/52B Table 5.6
# returns sampling rate (in kHz)
#
#####
sub getSamplingRate {
	my @samplingRate_table = (48,44.1,32,0);	#	'0' is really "reserved" in the spec
	return( $samplingRate_table[$_[0]] );
}

#####
#
# evalFrmsizecodValue()
#
# takes value (in decimal form) of frmsizecod and fscod
# does lookup in ATSC A/52B Table 5.18
# returns the number of 2-byte words per syncframe
#
#####
sub evalFrmsizecodValue {
	my $value = $_[0];
	my $samplerate = $_[1];
	my @thirtytwo_kHz_table = (96,96,120,120,144,144,168,168,192,192,240,240,288,288,336,336,384,384,480,480,576,576,672,672,768,768,960,960,1152,1152,1344,1344,1536,1536,1728,1728,1920,1920);
	my @fortyfour_kHz_table = (69,70,87,88,104,105,121,122,139,140,174,175,208,209,243,244,278,279,348,349,417,418,487,488,557,558,696,697,835,836,975,976,1114,1115,1253,1254,1393,1394);
	my @fortyeight_kHz_table = (64,64,80,80,96,96,112,112,128,128,160,160,192,192,224,224,256,256,320,320,384,348,448,448,512,512,640,640,768,768,896,896,1024,1024,1152,1152,1280,1280);
	
	if ( $samplerate eq 0 ) {	# 48 kHz
		return( $fortyeight_kHz_table[$value] );
	} elsif ( $samplerate = 1 ) {	# 44.1 kHz
		return( $fortyfour_kHz_table[$value] );
	} elsif ( $samplerate = 2 ) {	# 32 kHz
		return( $thirtytwo_kHz_table[$value] );	
	} else {	# reserved or bad value
		return 0;
	}
}

#####
#
# binary_to_decimal()
#
# takes bitfield strings (up to 32 bits long) and converts to decimal
#
# this is confusing so let me explain
# "0" x 32 = 00000000000000000000000000000000 ("0" times 32)
# shift grabs the first item of array @_, or the parameter passed to sub
# the . concatenates the 32 "0"s and the bit string passed to sub
# substr( foo, -32 ) returns the last 32 bytes of foo
# all this does is pad our bit string with leading zeros to make 32 bits
# pack "B32" converts a 32 bit field into a value
# unpack "N" converts that value into a scalar
#
#####
sub binary_to_decimal {
	return unpack( "N", pack( "B32", substr( "0" x 32 . shift, -32 ) ) );
}

#####
#
# interpret_bsid()
#
# bsid traditionally was only '01000' (8)
# but things have changed
#
# a standard AC-3 decoder should be able to decode anything with a bsid from 0..8
# a bsid of 6 is the Alternative Bitstream syntax (Annex D)
# a compliant standard AC-3 decoder shall mute anything with a bsid greater than 8
# a compliant Enhanced AC-3 (Annex E) decoder should be able to decode anything with a bsid of 0..8 and 11..16
# a compliant E-AC-3 decoder shall mute anything with a bsid of 9 or 10
# a compliant E-AC-3 decoder shall mute anything with a bsid greater than 16
#
#####
sub interpret_bsid {
	my $value = shift;
	if ( $value eq 8 ) { return "Standard AC-3 stream"; }
	if ( $value eq 6 ) { return "AC-3 with Alternative Bit Stream Syntax (Annex D)"; }
	if ( ( $value ge 0 ) && ( $value le 8 ) ) { return "Should be decodable by compliant AC-3/E-AC-3 decoder"; }
	if ( ( $value eq 9 ) || ( $value eq 10 ) ) {
		return "Non-standard stream - shall mute on compliant AC-3 and Enhanced AC-3 (Annex E) decoders";
		$warnings++;
	}
	if ( $value eq 16 ) { return "Standard Enhanced AC-3 (Annex E) stream"; }
	if ( ( $value ge 11 ) && ( $value le 15 ) ) {
		return "Backwards-compatible Enhanced AC-3 (Annex E) stream - should be decodable by E-AC-3 decoder, shall mute on a compliant AC-3 decoder";
	}
	if ( $value gt 16 ) {
		return "Shall mute on compliant AC-3 and Enhanced AC-3 (Annex E) decoders";
		$warnings++;
	}
	
	return( $value );
}

#####
#
# interpret_bsmod()
#
# bsmod		acmod		Type Of Service
# '000'		any			main audio service: complete main (CM)
# '001'		any			main audio service: music and effects (ME)
# '010'		any			associated service: visually impaired (VI)
# '011'		any			associated service: hearing impaired (HI)
# '100'		any			associated service: dialogue (D)
# '101'		any			associated service: commentary (C)
# '110'		any			associated service: emergency (E)
# '111'		'001'		associated service: voice over (VO)
# '111'		'010'-'111'	main audio service: karaoke
#
#####
sub interpret_bsmod {
	my $bsmod_value = shift;
	my $acmod_value = shift;
	if ( $bsmod_value eq 0 ) { return "main audio service: complete main (CM)"; }
	if ( $bsmod_value eq 1 ) { return "main audio service: music and effects (ME)"; }
	if ( $bsmod_value eq 2 ) { return "associated service: visually impaired (VI)"; }
	if ( $bsmod_value eq 3 ) { return "associated service: hearing impaired (HI)"; }
	if ( $bsmod_value eq 4 ) { return "associated service: dialogue (D)"; }
	if ( $bsmod_value eq 5 ) { return "associated service: commentary (C)"; }
	if ( $bsmod_value eq 6 ) { return "associated service: emergency (E)"; }
	if ( $bsmod_value eq 7 ) {
		if ( $acmod_value eq 1 ) { return "associated service: voice over (VO)"; }
		if ( ( $acmod_value ge 2 ) && ( $acmod_value le 7 ) ) {
			return "main audio service: karaoke";
		}
	}
	return "invalid";
}

#####
#
# interpret_acmod()
# 
# interpret Audio Coding Mode (acomd)
#
# acmod		Audio Coding Mode		nfchans		Channel Array Ordering
# '000'		1+1						2			Ch1, Ch2
# '001'		1/0						1			C
# '010'		2/0						2			L, R
# '011'		3/0						3			L, C, R
# '100'		2/1						3			L, R, S
# '101'		3/1						4			L, C, R, S
# '110'		2/2						4			L, R, SL, SR
# '111		3/2						5			L, C, R, SL, SR
#
#####
sub interpret_acmod {
	my $acmod_value = shift;
	if ( $acmod_value eq 0 ) { return "1+1: Ch1, Ch2"; }
	if ( $acmod_value eq 1 ) { return "1/0: C"; }
	if ( $acmod_value eq 2 ) { return "2/0: L, R"; }
	if ( $acmod_value eq 3 ) { return "3/0: L, C, R"; }
	if ( $acmod_value eq 4 ) { return "2/1: L, R, S"; }
	if ( $acmod_value eq 5 ) { return "3/1: L, C, R, S"; }
	if ( $acmod_value eq 6 ) { return "2/2: L, R, SL, SR"; }
	if ( $acmod_value eq 7 ) { return "3/2: L, C, R, SL, SR"; }
	return "invalid";
}

#####
#
# interpret_cmixlev()
#
# interpret Center Mix Level (cmixlev)
#
# cmixlev
# '00' (0) = 0.707 (-3.0 dB)
# '01' (1) = 0.595 (-4.5 dB)
# '10' (2) = 0.500 (-6.0 dB)
# '11' (3) = reserved
#
#####
sub interpret_cmixlev {
	my $value = shift;
	if ( $value eq 0 ) { return "0.707 (-3.0 dB)"; }
	if ( $value eq 1 ) { return "0.595 (-4.5 dB)"; }
	if ( $value eq 2 ) { return "0.500 (-6.0 dB)"; }
	if ( $value eq 3 ) { return "reserved"; }
}

#####
#
# interpret_surmixlev()
#
# interpret Surround Mix Level (surmixlev)
#
# surmixlev		slev
# '00'			0.707 (-3.0 dB)
# '01'			0.500 (-6.0 dB)
# '10'			0
# '11'			rserved
#
#####
sub interpret_surmixlev {
	my $surmixlev_value = shift;
	if ( $surmixlev_value eq 0 ) { return "0.707 (-3.0 dB)"; }
	if ( $surmixlev_value eq 1 ) { return "0.500 (-6.0 dB)"; }
	if ( $surmixlev_value eq 2 ) { return "0"; }
	if ( $surmixlev_value eq 3 ) { return "reserved"; }	
}

#####
#
# interpret_dsurmod()
#
# interpret Dolby Surround Mode (dsmod)
# 
# dsmod		Indication
# '00'		not indicated
# '01'		Not Dolby Surround encoded
# '10'		Dolby Surround encoded
# '11'		reserved
#
#####
sub interpret_dsurmod {
	my $dsurmod_value = shift;
	if ( $dsurmod_value eq 0 ) { return "not indicated"; }
	if ( $dsurmod_value eq 1 ) { return "Not Dolby Surround encoded"; }
	if ( $dsurmod_value eq 2 ) { return "Dolby Surround encoded"; }
	if ( $dsurmod_value eq 3 ) { return "reserved"; }
}

#####
#
# interpret dialnorm()
#
# interpret Dialog Normalization (dialnorm)
#
# dialnorm 1..31 is -1 to -31 dB
# dialnorm of 0 is reserved, but shall be -31 dB
#
#####
sub interpret_dialnorm {
	my $dialnorm_value = shift;
	if ( $dialnorm_value eq 0 ) { return "reserved (-31 dB)"; }
	else { return "-" . $dialnorm_value . " dB"; }
}

#####
#
# compr_value()
#
# take compression gain word bitfield
#
# compression gain word is 8 bits
# XXXXYYYY
# XXXX is a signed 4 bit integer (call this x)
# (x+1)*6.02 dB is a starting value that can be -42.14 dB to +48.16
#
# YYYY is an unsigned integer (call this y)
# 0.1YYYY (base 2), which can represent values of -0.28 dB to -6.02 dB
# this is added to base x value, so the gain change can be from -48.16 dB to +47.89 dB
#
# I don't fully understand the 0.1YYYY bit yet
# 
# 
#
#####
sub compr_value {
	my @signed_nibble_table = (0,1,2,3,4,5,6,7,-8,-7,-6,-5,-4,-3,-2,-1);
	
	my $compr_word_bitfield = shift;
	my $X_bitfield = substr( $compr_word_bitfield, 0, 4 );
	my $Y_bitfield = substr( $compr_word_bitfield, 4, 4 );
	
	my $X_byte = "0000" . $X_bitfield;					# pad 4 msb with 0
	my $X_value = binary_to_decimal( $X_bitfield );		# convert to an unsigned int value
	
	my $Y_value = 1 * ( 2 ** -1 );
	$Y_value += substr( $Y_bitfield, 0, 1 ) * ( 2 ** -2 );
	$Y_value += substr( $Y_bitfield, 1, 1 ) * ( 2 ** -3 );
	$Y_value += substr( $Y_bitfield, 2, 1 ) * ( 2 ** -4 );
	$Y_value += substr( $Y_bitfield, 3, 1 ) * ( 2 ** -5 );
	
	my $Y_gain_value = 20 * log( $Y_value ) / log( 10 );
	
	my $gain_value = ( ( @signed_nibble_table[$X_value] + 1 ) * 6.02 ) + ( 20 * log( $Y_value ) / log( 10 ) );
	
	return( $gain_value );
}

#####
# 
# interpret_langcod()
#
# interpret Language Code (langocd)
#
# OK, so this field was depreciated at some point before A/52:2012
# in favor of ISO-639 language code in the wrapper
# the current A/52 spec says this should be 0xFF
# but in most cases, the value will be 0x9, English
#
# oanguage list take from my C++ program, which referenced an older version of the spec
#
#####
sub interpret_langcod {
	my $langcod_value = shift;
	if ( $langcod_value eq 255 ) { return "reserved (default value)"; }
	if ( $langcod_value eq 0 ) { return "unknown/NA"; }
	if ( $langcod_value eq 1 ) { return "Albanian"; }
	if ( $langcod_value eq 2 ) { return "Breton"; }
	if ( $langcod_value eq 3 ) { return "Catalan"; }
	if ( $langcod_value eq 4 ) { return "Croatian"; }
	if ( $langcod_value eq 5 ) { return "Welsh"; }
	if ( $langcod_value eq 6 ) { return "Czech"; }
	if ( $langcod_value eq 7 ) { return "Danish"; }
	if ( $langcod_value eq 8 ) { return "German"; }
	if ( $langcod_value eq 9 ) { return "English"; }
	if ( $langcod_value eq 10 ) { return "Spanish"; }
	if ( $langcod_value eq 11 ) { return "Esperanto"; }
	if ( $langcod_value eq 12 ) { return "Estonian"; }
	if ( $langcod_value eq 13 ) { return "Basque"; }
	if ( $langcod_value eq 14 ) { return "Faroese"; }
	if ( $langcod_value eq 15 ) { return "French"; }
	if ( $langcod_value eq 16 ) { return "Frisian"; }
	if ( $langcod_value eq 17 ) { return "Irish"; }
	if ( $langcod_value eq 18 ) { return "Gaelic"; }
	if ( $langcod_value eq 19 ) { return "Galician"; }
	if ( $langcod_value eq 20 ) { return "Icelandic"; }
	if ( $langcod_value eq 21 ) { return "Italian"; }
	if ( $langcod_value eq 22 ) { return "Lappish"; }
	if ( $langcod_value eq 23 ) { return "Latin"; }
	if ( $langcod_value eq 24 ) { return "Latvian"; }
	if ( $langcod_value eq 25 ) { return "Luxembourgian"; }
	if ( $langcod_value eq 26 ) { return "Lithuanian"; }
	if ( $langcod_value eq 27 ) { return "Hungarian"; }
	if ( $langcod_value eq 28 ) { return "Maltese"; }
	if ( $langcod_value eq 29 ) { return "Dutch"; }
	if ( $langcod_value eq 30 ) { return "Norwegian"; }
	if ( $langcod_value eq 31 ) { return "Occitan"; }
	if ( $langcod_value eq 32 ) { return "Polish"; }
	if ( $langcod_value eq 33 ) { return "Portuguese"; }
	if ( $langcod_value eq 34 ) { return "Romanian"; }
	if ( $langcod_value eq 35 ) { return "Romanish"; }
	if ( $langcod_value eq 36 ) { return "Serbian"; }
	if ( $langcod_value eq 37 ) { return "Slovak"; }
	if ( $langcod_value eq 38 ) { return "Slovene"; }
	if ( $langcod_value eq 39 ) { return "Finnish"; }
	if ( $langcod_value eq 40 ) { return "Swedish"; }
	if ( $langcod_value eq 41 ) { return "Turkish"; }
	if ( $langcod_value eq 42 ) { return "Flemish"; }
	if ( $langcod_value eq 43 ) { return "Waloon"; }
	if ( $langcod_value eq 44 ) { return "undefined"; }
	if ( $langcod_value eq 45 ) { return "undefined"; }
	if ( $langcod_value eq 46 ) { return "undefined"; }
	if ( $langcod_value eq 47 ) { return "undefined"; }
	if ( $langcod_value eq 48 ) { return "reserved"; }
	if ( $langcod_value eq 49 ) { return "reserved"; }
	if ( $langcod_value eq 50 ) { return "reserved"; }
	if ( $langcod_value eq 51 ) { return "reserved"; }
	if ( $langcod_value eq 52 ) { return "reserved"; }
	if ( $langcod_value eq 53 ) { return "reserved"; }
	if ( $langcod_value eq 54 ) { return "reserved"; }
	if ( $langcod_value eq 55 ) { return "reserved"; }
	if ( $langcod_value eq 56 ) { return "reserved"; }
	if ( $langcod_value eq 57 ) { return "reserved"; }
	if ( $langcod_value eq 58 ) { return "reserved"; }
	if ( $langcod_value eq 59 ) { return "reserved"; }
	if ( $langcod_value eq 60 ) { return "reserved"; }
	if ( $langcod_value eq 61 ) { return "reserved"; }
	if ( $langcod_value eq 62 ) { return "reserved"; }
	if ( $langcod_value eq 63 ) { return "reserved"; }
	if ( $langcod_value eq 64 ) { return "bg sound"; }
	if ( $langcod_value eq 65 ) { return "unknown"; }
	if ( $langcod_value eq 66 ) { return "unknown"; }
	if ( $langcod_value eq 67 ) { return "unknown"; }
	if ( $langcod_value eq 68 ) { return "unknown"; }
	if ( $langcod_value eq 69 ) { return "Zulu"; }
	if ( $langcod_value eq 70 ) { return "Vietnamese"; }
	if ( $langcod_value eq 71 ) { return "Uzbek"; }
	if ( $langcod_value eq 72 ) { return "Urdu"; }
	if ( $langcod_value eq 73 ) { return "Ukrainian"; }
	if ( $langcod_value eq 74 ) { return "Thai"; }
	if ( $langcod_value eq 75 ) { return "Telugu"; }
	if ( $langcod_value eq 76 ) { return "Tatar"; }
	if ( $langcod_value eq 77 ) { return "Tamil"; }
	if ( $langcod_value eq 78 ) { return "Tadzhik"; }
	if ( $langcod_value eq 79 ) { return "Swahili"; }
	if ( $langcod_value eq 80 ) { return "Sranan Tongo"; }
	if ( $langcod_value eq 81 ) { return "Somali"; }
	if ( $langcod_value eq 82 ) { return "Sinhalese"; }
	if ( $langcod_value eq 83 ) { return "Shona"; }
	if ( $langcod_value eq 84 ) { return "Serbo-Croat"; }
	if ( $langcod_value eq 85 ) { return "Ruthenian"; }
	if ( $langcod_value eq 86 ) { return "Russian"; }
	if ( $langcod_value eq 87 ) { return "Quechua"; }
	if ( $langcod_value eq 88 ) { return "Pustu"; }
	if ( $langcod_value eq 89 ) { return "Punjabi"; }
	if ( $langcod_value eq 90 ) { return "Persian"; }
	if ( $langcod_value eq 91 ) { return "Papamiento"; }
	if ( $langcod_value eq 92 ) { return "Oriya"; }
	if ( $langcod_value eq 93 ) { return "Nepali"; }
	if ( $langcod_value eq 94 ) { return "Ndebele"; }
	if ( $langcod_value eq 95 ) { return "Marathi"; }
	if ( $langcod_value eq 96 ) { return "Moldavian"; }	
	if ( $langcod_value eq 97 ) { return "Malaysian"; }
	if ( $langcod_value eq 98 ) { return "Malagasay"; }
	if ( $langcod_value eq 99 ) { return "Macedonian"; }
	if ( $langcod_value eq 100 ) { return "Laotian"; }
	if ( $langcod_value eq 101 ) { return "Korean"; }
	if ( $langcod_value eq 102 ) { return "Khmer"; }
	if ( $langcod_value eq 103 ) { return "Kazakh"; }
	if ( $langcod_value eq 104 ) { return "Kannada"; }
	if ( $langcod_value eq 105 ) { return "Japanese"; }
	if ( $langcod_value eq 106 ) { return "Indonesian"; }
	if ( $langcod_value eq 107 ) { return "Hindi"; }
	if ( $langcod_value eq 108 ) { return "Hebrew"; }
	if ( $langcod_value eq 109 ) { return "Hausa"; }
	if ( $langcod_value eq 110 ) { return "Gurani"; }
	if ( $langcod_value eq 111 ) { return "Gujurati"; }
	if ( $langcod_value eq 112 ) { return "Greek"; }
	if ( $langcod_value eq 113 ) { return "Georgian"; }
	if ( $langcod_value eq 114 ) { return "Fulani"; }
	if ( $langcod_value eq 115 ) { return "Dari"; }
	if ( $langcod_value eq 116 ) { return "Churash"; }
	if ( $langcod_value eq 117 ) { return "Chinese"; }
	if ( $langcod_value eq 118 ) { return "Burmese"; }
	if ( $langcod_value eq 119 ) { return "Bulgarian"; }
	if ( $langcod_value eq 120 ) { return "Bengali"; }
	if ( $langcod_value eq 121 ) { return "Belorussian"; }
	if ( $langcod_value eq 122 ) { return "Bambora"; }
	if ( $langcod_value eq 123 ) { return "Azerbijani"; }
	if ( $langcod_value eq 124 ) { return "Assamese"; }
	if ( $langcod_value eq 125 ) { return "Armenian"; }
	if ( $langcod_value eq 126 ) { return "Arabic"; }
	if ( $langcod_value eq 127 ) { return "Amharic"; }
	return( "not recognized" );
}

#####
#
# interpret_mixlev()
#
# interpret Mixing Level (mixlev)
#
# This 5-bit code indicates the absolute acoustic sound pressure level of an individual
# channel during the final audio mixing session. The 5-bit code represents a value in the
# range 0 to 31. The peak mixing level is 80 plus the value of mixlevel dB SPL, or
# 80 to 111 dB SPL. The peak mixing level is the acoustic level of a sine wave in a single
# channel whose peaks reach 100 percent in the PCM representation. The absolute SPL value
# is typically measured by means of pink noise with an RMS value of -20 or -30 dB with
# respect to the peak RMS sine wave level. The value of mixlevel is not typically used
# within the AC-3 decoder, but may be used by other parts of the audio reproduction equipment.
#
#####
sub interpret_mixlev {
	my $mixlev_value = shift;
	return( $mixlev_value + 80 );
}

#####
#
# interpret_roomtyp()
#
# interpret Room Type (roomtyp)
#
# roomtyp		Type of Mixing Room
# '00'			not indicated
# '01'			large room, X curve monitor
# '10'			small room, flat monitor
# '11'			reserved
#
#####
sub interpret_roomtyp {
	my $roomtyp_value = shift;
	if ( $roomtyp_value eq 0 ) { return "not indicated"; }
	if ( $roomtyp_value eq 1 ) { return "large room, X curve monitor"; }
	if ( $roomtyp_value eq 2 ) { return "small room, flat monitor"; }
	if ( $roomtyp_value eq 3 ) { return "reserved"; }
}

#####
#
# decode_timecode()
#
# take timecod1 and timecod2 and turn them into a formatted timecode value
# HH:MM:SS:FF+ff
# (+ff = 1/64th frame fraction)
#
# 	timecod1
# 	00 01 02 03 04 05 06 07 08 09 10 11 12 13
# 	HH HH HH HH HH MM MM MM MM MM MM SS SS SS
#
# 	timecod2
# 	00 01 02 03 04 05 06 07 08 09 10 11 12 13
# 	SS SS SS FF FF FF FF FF ff ff ff ff ff ff
#
# 	timecod1 5 bits = hour (0..24)
# 	timecod1 6 bits = minutes (0..59)
# 	timecod1 3 bits = 8 second increments (0, 8, 16, 24, 32, 40, 56)
# 	timecod2 3 bits = additional seconds (0..7)
# 	timecod2 5 bits = frames (0..29)
# 	timecod2 6 bits = 1/64th frame fraction (0..63)
#
# both bitfields are NOT necessary to decode a timecode that is usable
# how do handle this?
#
# I can't 
#
#####
sub decode_timecode {
	my $timecod1_value = shift;
	my $timecod2_value = shift;
	
	my ( $output, $hours, $minutes, $seconds, $frames, $fraction );
	my ( $hour_bits, $minute_bits, $big_second_bits );
	my ( $little_second_bits, $frame_bits, $fraction_bits );
	
	$hour_bits = substr( $timecod1_value, 0, 5 );
	$minute_bits = substr( $timecod1_value, 5, 6 );
	$big_second_bits = substr( $timecod1_value, 11, 3 );
	$little_second_bits = substr( $timecod2_value, 0, 3 );
	$frame_bits = substr( $timecod2_value, 3, 5 );
	$fraction_bits = substr( $timecod2_value, 8, 6 );
	
	$hours = sprintf( "%02d", binary_to_decimal( $hour_bits ) );
	$minutes = sprintf( "%02d", binary_to_decimal( $minute_bits ) );
	$seconds = sprintf( "%02d", ( binary_to_decimal( $big_second_bits) * 8 ) + binary_to_decimal( $little_second_bits ) );
	$frames = sprintf( "%02d", binary_to_decimal( $frame_bits ) );
	$fraction = sprintf( "%02d", binary_to_decimal( $fraction_bits ) );
	
	$output = "$hours:$minutes:$seconds:$frames+$fraction";
	
	return $output;
}

sub decode_preamble_timecode {
	my $preamble = shift;
	my $timecode;
	
	my $preamble_pointer;
	my ( $pre_hours_byte, $pre_minutes_byte, $pre_seconds_byte, $pre_frames_byte, $pre_samples_word );
	my ( $pre_hours, $pre_minutes, $pre_seconds, $pre_frames, $pre_samples );
	
	# first three bytes of preamble are a header of some sort
	# is 0x 01 10 00 in all examples I have
	# so we'll just skip it
	$preamble_pointer = 3;
	
	# get hours
	$pre_hours_byte = substr( $preamble, $preamble_pointer++, 1 );
	$pre_hours = (10 * ( ord( pack( 'B8', ( "0000" . substr( unpack( 'B8', $pre_hours_byte), 0, 4 ) ) ) ) ) ) +
		( ord( pack( 'B8', ( "0000" . substr( unpack( 'B8', $pre_hours_byte ), 4, 4 ) ) ) ) );
#	print "***** preamble hours hex: " . unpack( "H*", $pre_hours_byte ) . " *****\n";
#	print "***** preamble hours: $pre_hours *****\n";
#	print "\n";
	
	# skip over next (empty) byte
	$preamble_pointer++;
	
	# get minutes
	$pre_minutes_byte = substr( $preamble, $preamble_pointer++, 1 );
	$pre_minutes = (10 * ( ord( pack( 'B8', ( "0000" . substr( unpack( 'B8', $pre_minutes_byte), 0, 4 ) ) ) ) ) ) +
		( ord( pack( 'B8', ( "0000" . substr( unpack( 'B8', $pre_minutes_byte ), 4, 4 ) ) ) ) );
#	print "***** preamble minutes hex: " . unpack( "H*", $pre_minutes_byte ) . " *****\n";
#	print "***** preamble minutes: $pre_minutes *****\n";
#	print "\n";
	
	# skip over next (empty) byte
	$preamble_pointer++;
	
	# get seconds
	$pre_seconds_byte = substr( $preamble, $preamble_pointer++, 1 );
	$pre_seconds = (10 * ( ord( pack( 'B8', ( "0000" . substr( unpack( 'B8', $pre_seconds_byte), 0, 4 ) ) ) ) ) ) +
		( ord( pack( 'B8', ( "0000" . substr( unpack( 'B8', $pre_seconds_byte ), 4, 4 ) ) ) ) );
#	print "***** preamble seconds hex: " . unpack( "H*", $pre_seconds_byte ) . " *****\n";
#	print "***** preamble seconds: $pre_seconds *****\n";
#	print "\n";	
	
	$preamble_pointer++;
	
	# get frames
	$pre_frames_byte = substr( $preamble, $preamble_pointer++, 1 );
	$pre_frames = (10 * ( ord( pack( 'B8', ( "0000" . substr( unpack( 'B8', $pre_frames_byte), 0, 4 ) ) ) ) ) ) +
		( ord( pack( 'B8', ( "0000" . substr( unpack( 'B8', $pre_frames_byte ), 4, 4 ) ) ) ) );
#	print "***** preamble frames hex: " . unpack( 'H*', $pre_frames_byte ) . " *****\n";
#	print "***** preamble frames: $pre_frames *****\n";
#	print "\n";
	
	# get samples
	$pre_samples_word = substr( $preamble, $preamble_pointer, 2 );
	$pre_samples = binary_to_decimal( unpack( 'B16', $pre_samples_word ) );
#	print "***** preamble samples hex: " . unpack( 'H*', $pre_samples_word ) . " *****\n";
#	print "***** preamble samples: $pre_samples *****\n";
	
	$timecode = sprintf( '%02d', $pre_hours ) . ":" .
				sprintf( '%02d', $pre_minutes ) . ":" .
				sprintf( '%02d', $pre_seconds ) . ":" .
				sprintf( '%02d', $pre_frames ) . "+" .
				sprintf( '%04d', $pre_samples );
	
	return( $timecode );
}
