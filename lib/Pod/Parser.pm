# lib/Pod/Parser.pm - Perl 6 Plain Old Documentation parser

# Names, meanings and sequence according to Synopsis 26 - Documentation

# warning - code in here is being significantly refactored.
# statements that are almost duplicated are in transition, for example
# @.blocks -> @!podblocks and $line -> $!line.

class Pod::Parser {

    has PodBlock @!podblocks;       # stack of nested Pod blocks
    has          @.blocks is rw;    # stack of nested blocks.
#   has          %!config;          # for =config definitions
    has IO       $!outfile;         # could be replaced by select()
    has Str      $!context;         # 'AMBIENT', 'BLOCK_DECLARATION' or 'POD_CONTENT'
    has Str      $!line;
    has Str      $!buf_out_line;
    has Bool     $!buf_out_enable;
    has Bool     $!wrap_enable;
    has Bool     $!codeblock;
    has Bool     $!needspace;       # would require ' ' if more text follows
    has Int      $!margin_L;
    has Int      $!margin_R;
    # enum Context <AMBIENT BLOCK_DECLARATION POD_CONTENT>;
    # has $!context is rw is Context; # not (yet) in Rakudo

    method parse_file( Str $filename )
    {
        $!context        = 'AMBIENT';
        $!outfile        = $*OUT;     # for possible redirection to other files
        $!buf_out_line   = '';
        $!buf_out_enable = Bool::True;
        $!wrap_enable    = Bool::True;
        $!codeblock      = Bool::False;
        $!needspace      = Bool::True;
        $!margin_L       = 0;
        $!margin_R       = 79;
        # the main stream based parser begins here
        self.doc_beg( $filename );
        my IO $handle = open $filename, :r ;
        for =$handle -> Str $line {
            self.parse_line( $line );
        }
        close $handle;
        self.doc_end;
    }

    # TODO: change most following methods to submethods ASAP
    method parse_line( Str $line ) { # from parse_file
        $!line = $line;
        given $!line {
            when Pod6::directive {   self.parse_directive; } # eg '=xxx :ccc'
            when Pod6::extra     {   self.parse_configuration( $0 ); } # eg '= :ccc'
            when Pod6::blank     {   self.parse_blank; }     # eg '' or ' '
            default              {   if @!podblocks {        # eg 'xxx' or ' xxx'
                                         self.parse_content( $line );
#                                        self.parse_content;
                                     } else {
                                         self.ambient( $!line ); # not pod
                                     }
                                 }
        }
    }

    method parse_directive { # from parse_line
        given $!line {
            # Keywords from Synopsis 26 section "markers"
            when Pod6::begin    { self.parse_begin(    $/ ); }
            when Pod6::end      { self.parse_end(      $/ ); }
            when Pod6::for      { self.parse_for(      $/ ); }
            # Keywords from Synopsis 26 section "Blocks"
            when Pod6::code     { self.parse_code(     $/ ); }
            when Pod6::comment  { self.parse_comment(  $/ ); }
            when Pod6::head     { self.parse_head(     $/ ); }
            when Pod6::input    { }
            when Pod6::item     { }
            when Pod6::nested   { }
            when Pod6::output   { }
            when Pod6::table    { }
            when Pod6::DATA     { }
            when Pod6::END      { }
            # Keywords from Synopsis 26 section "Block pre-configuration"
            when Pod6::encoding { }
            when Pod6::config   { self.parse_config(   $/ ); }
            when Pod6::use      { }
            # Keywords from Perl 5 POD
            when Pod6::p5pod    { self.parse_p5pod; }
            when Pod6::p5over   { }
            when Pod6::p5back   { }
            when Pod6::p5cut    { self.parse_p5cut;}
            default             {
                                # self.parse_user_defined;
                                }
        }
    }

    method parse_configuration( Str $line ) # from parse_line
    {
        if $!context ne 'BLOCK_DECLARATION' {
            warning "extended configuration without marker";
        };
        # TODO: parse various pair notations
    }

    method parse_blank { # from parse_line
        if @!podblocks { # in some POD block
            my Int $topindex = @!podblocks.end;
            my Str $style = @!podblocks[$topindex].style; # does Rakudo [*-1] yet?
            if $style eq ( 'PARAGRAPH' | 'ABBREVIATED' | 'FORMATTING_CODE' ) {
                # TODO: consider loop for possible nested formatting codes still open
                self.set_context( 'AMBIENT' ); # close paragraph block
            }
            elsif @!podblocks[$topindex].typename eq 'code' {
                self.content( @.blocks[$topindex], '' ); # blank line is part of code
            }
        }
        else { self.ambient( '' ); } # a non POD part of the file
    }

    method parse_content( Str $line ) # from parse_line
#   method parse_content # from parse_line
    {
        self.set_context( 'POD_CONTENT' );
        # (hopefully not premature) optimization: format only if contains < or > chars.
        $!line = $line;
        my Int $topindex = @!podblocks.end;
        if $!line ~~ /[<lt>|<gt>|'«'|'»']/ {self.parse_formatting;}
        else                       {self.content(@.blocks[$topindex],$line);}  # [*-1]
#       else                       {self.content(@.blocks[$topindex],$!line);} # [*-1]
    }

    method parse_formatting { # from parse_content and parse_head
        # It is valid to call parse_formatting with lines that do not
        # contain formatting, it just wastes a bit of time.
        my Str $content = $!line;
        while $content.chars > 0 {
            my Str $format_begin;
            my Str $angle_L; #  « | < | << | <<< etc char(s) found
            my Str $angle_R; #  >>> | >> | > | »     char(s) to be found
            my Int $format_begin_pos = $content.chars;
            my Int $angle_L_pos      = $content.chars;
            my Int $angle_R_pos      = $content.chars;
            my Str $output_buffer    = $content; # assuming all formatting done
            my Int $chars_to_delete  = $content.chars;
            # Check for possible formatting codes currently open
            if @!podblocks {
                # TODO: check that it is correct to look only at the
                # innermost block (last pushed).
                # What if '=begin comment' is nested inside a format
                # block (S26)?
                my Int $topindex = @!podblocks.end;
                my Hash $reftopblock = @.blocks[$topindex]; # [*-1]
#               my PodBlock $topblock = @!podblocks[$topindex]; # [*-1]
                my          $topblock = @!podblocks[$topindex]; # [*-1]
#               $*ERR.say: "TOPBLOCK: {$topblock.WHAT}";
                if $topblock.style eq 'FORMATTING_CODE' {
                    # Found an open formatting code. Get its delimiters.
                    $angle_L     = $topblock.config<angle_L>;
                    $angle_R     = $topblock.config<angle_R>;
                    # Search for possible nested delimiters.
                    # eg this 'C< if $a < $b or $a > $b >' is all code.
                    if $content.index( $angle_L ) {
                        $angle_L_pos = $content.index( $angle_L );
                    }
                    if $content.index( $angle_R ) {
                        $angle_R_pos = $content.index( $angle_R );
                    }
                }
            }
            # TODO: rewrite pattern with variable list of allowed codes
#           if $content ~~ / (.*?)(<[BCDEIKLMNPRSTUVXZ]>)(\<+|'«')(.*) / {
            if $content ~~ / (.*?)(<[BCDEIKLMNPRSTUVXZ]>)(\<+)(.*) / {
                my Str $before      = ~ $0;
                $format_begin       = ~ $1;
                my Str $new_angle_L = ~ $2;
                my Str $after       = ~ $3;
                $format_begin_pos   = $1.from;
                my Int $format_end_pos  = $2.to;
                if $format_begin_pos < $angle_L_pos and $format_begin_pos < $angle_R_pos {
                    my Str $new_angle_R = $new_angle_L eq '«' ?? '»' !!
                        '>' x $new_angle_L.chars;
                    my %formatblock = (
                        'typename' => ~ $format_begin,
                        'style'    => 'FORMATTING_CODE',
                        'config'   => { 'angle_L' => ~ $new_angle_L, 'angle_R' => ~ $new_angle_R }
                    );
                    # my PodBlock $formatcodeblock
                    my $formatcodeblock = PodBlock.new(
                        typename => ~ $format_begin,
                        style    => 'FORMATTING_CODE',
                        config   => { 'angle_L' => ~ $new_angle_L,
                                      'angle_R' => ~ $new_angle_R }
                    );
                    if $format_begin eq 'L' {
                        parse_link( $/, \%formatblock );
                    }
                    if $format_begin_pos > 0 {
                        # There is text before the new formatting code
                        my $before = $content.substr( 0, $format_begin_pos );
                        my Int $topindex = @!podblocks.end;
                        self.content( @.blocks[$topindex], $before ); # [*-1]
                    }
                    @.blocks.push( \%formatblock );
                    @!podblocks.push( $formatcodeblock );
                    self.fmt_beg( %formatblock );
                    $chars_to_delete = $format_end_pos;
                    $output_buffer = "";
                }
            }
            if $angle_L_pos < $format_begin_pos and $angle_L_pos < $angle_R_pos {
                my %formatblock = (
                    'typename' => "NESTED_ANGLE_BRACKET",
                    'style'    => 'FORMATTING_CODE',
                    'config'   => { 'angle_L' => $angle_L, 'angle_R' => $angle_R }
                );
                # my PodBlock $formatcodeblock
                my $formatcodeblock = PodBlock.new(
                    typename => "NESTED_ANGLE_BRACKET",
                    style    => 'FORMATTING_CODE',
                    config   => { 'angle_L' => $angle_L,
                                  'angle_R' => $angle_R }
                );
                @.blocks.push( \%formatblock );
                @!podblocks.push( $formatcodeblock );
                $output_buffer = $content.substr( 0, $angle_L_pos + $angle_L.chars );
                $chars_to_delete = $angle_L_pos + $angle_L.chars;
            }
            elsif $angle_R_pos < $format_begin_pos and $angle_R_pos < $angle_L_pos {
                my $reftopblock = pop @.blocks;
#               $*ERR.say: "REFTOPBLOCK: " ~ $reftopblock.perl;
                # my PodBlock $topblock
                my $topblock = pop @!podblocks;
#               $*ERR.say: "TOPBLOCK:" ~ $topblock.perl;
                my $typename = $topblock.typename;
                if $typename eq "NESTED_ANGLE_BRACKET" {
                    $output_buffer = $content.substr( 0, $angle_R_pos + $angle_R.chars );
                }
                else {
                    $output_buffer = $content.substr( 0, $angle_R_pos );
                    my Int $topindex = @!podblocks.end;
                    self.content( @.blocks[$topindex], $output_buffer ); # [*-1]
                    $output_buffer = "";
                    self.fmt_end( $reftopblock );
                }        
                $chars_to_delete = $angle_R_pos + $angle_R.chars;
            }
            if $output_buffer.chars > 0 { # TODO: if $output_buffer.chars
                my Int $topindex = @!podblocks.end;
                self.content( $.blocks[$topindex], $output_buffer ); # [*-1]
            }
            $content = $content.substr( $chars_to_delete );
        }
    }

    sub parse_link( Match $match, $refblock ) { # from parse_formatting
        # matched / (.*?)(<[BCDEIKLMNPRSTUVXZ]>)(\<+)(.*) /
        my $angle_R = $refblock<config><angle_R>;
        my Str $s = ~ $match[3];
        my $index = $s.index( $angle_R );
        my $link = $s.substr( 0, $index );
        if $link ~~ Pod6_link {
            $refblock<config><alternate> = ~ $/<alternate>;
            $refblock<config><scheme>    = ~ $/<scheme>;
            $refblock<config><external>  = ~ $/<external>;
            $refblock<config><internal>  = ~ $/<internal>;
            # tweak some of the link fields
            $refblock<config><scheme>   .= subst( / ^ $ /, {'doc'} ); # no scheme becomes doc
            $refblock<config><scheme>   .= subst( / \: $ /, { '' } ); # remove : from scheme:
            $refblock<config><internal> .= subst( / ^ \# /, { '' } ); # remove # from #internal
        }
    }

#   method parse_begin( Match $match ) { # from parse_directive
    method parse_begin(       $match ) { # from parse_directive
        # $*ERR.say: "MATCH: {$match.WHAT}";
        my Str $typename = ~ $match<typename>;
        self.set_context( 'AMBIENT' ); # finish any previous block
        self.set_context( 'BLOCK_DECLARATION' );
        my Int $topindex = @!podblocks.end;
        @.blocks[$topindex]<typename> = $typename;    # [*-1] eventually
        @.blocks[$topindex]<style> = 'DELIMITED';     # [*-1]
        @!podblocks[$topindex].typename = $typename;  # [*-1] eventually
        @!podblocks[$topindex].style    = 'DELIMITED';# [*-1]
        given $typename {
            when 'pod' {
                @.blocks[$topindex]<config><version> = 6;   # [*-1]
                @!podblocks[$topindex].config<version> = 6; # [*-1]
            }
            when 'code' { $!codeblock = Bool::True; $!wrap_enable = Bool::False; }
        }
    }

#   method parse_end( Match $match ) { # from parse_directive
    method parse_end(       $match ) { # from parse_directive
        self.set_context( 'AMBIENT' );
        my Hash $reftopblock = pop @.blocks;
        # my PodBlock $topblock = pop @!podblocks;
        my $topblock = pop @!podblocks;
        my Str $poptypename = $topblock.typename;
        my Str $endtypename = ~ $match<typename>;
        if ( $poptypename ne $endtypename ) {
            # TODO: change to non fatal diagnostic
            die "=end expected $poptypename, got $endtypename";
        }
        if $endtypename eq 'code' { $!codeblock = Bool::False; $!wrap_enable = Bool::True; }
        self.blk_end( $reftopblock );
    }

#   method parse_for( Match $match ) { # from parse_directive
    method parse_for(       $match ) { # from parse_directive
        self.set_context( 'BLOCK_DECLARATION' );
        my Int $topindex = @!podblocks.end;
        @.blocks[$topindex]<typename> = ~ $match<typename>; # [*-1]
        @.blocks[$topindex]<style> = 'ABBREVIATED';         # [*-1]
        @!podblocks[$topindex].typename = ~ $match<typename>; # [*-1]
        @!podblocks[$topindex].style = 'ABBREVIATED';         # [*-1]
    }

#   method parse_code( Match $match ) # from parse_directive
    method parse_code(       $match ) # from parse_directive
    {
    }

#   method parse_head( Match $match ) { # from parse_directive
    method parse_head(       $match ) { # from parse_directive
        # when not in pod, =head implies Perl 5 =pod
        if + @.blocks == 0 { self.parse_p5pod; } # inserts =pod version=>5
        
        my Str $heading = ~ $match<heading>;
        self.set_context( 'AMBIENT' );        
        self.set_context( 'BLOCK_DECLARATION' ); # pushes a new empty block onto the stack
        my Int $topindex = @!podblocks.end;
        @.blocks[$topindex]<typename> = 'head';               # [*-1]
        @.blocks[$topindex]<style>    = 'POD_BLOCK';          # [*-1]
        @.blocks[$topindex]<config><level> = ~ $match<level>; # [*-1]
        @!podblocks[$topindex].typename = 'head';               # [*-1]
        @!podblocks[$topindex].style    = 'POD_BLOCK';          # [*-1]
        @!podblocks[$topindex].config<level> = ~ $match<level>; # [*-1]
        self.set_context( 'POD_CONTENT' ); # this one won't add a PARAGRAPH block
        $!line = ~ $match<heading>;
        self.parse_formatting;
        self.blk_end( pop @.blocks ); # the 'head'
        pop @!podblocks;
        self.set_context( 'AMBIENT' );
    }

#   method parse_comment( Match $match ) { # from parse_directive
    method parse_comment(       $match ) { # from parse_directive
    }

#   method parse_config( Match $match ) { # from parse_directive
    method parse_config(       $match ) { # from parse_directive
        my $typename = $match<typename>;
        my $options  = $match<option>[0];
        self.emit( "=config $typename $options" );
    }

    method parse_p5pod { # from parse_directive
        self.set_context( 'AMBIENT' ); # finish any previous block
        self.set_context( 'BLOCK_DECLARATION' );
        my Int $topindex = @!podblocks.end;
        @.blocks[$topindex]<typename>        = 'pod';       # [*-1] eventually
        @.blocks[$topindex]<style>           = 'DELIMITED'; # [*-1]
        @.blocks[$topindex]<config><version> = 5;           # [*-1]
        @!podblocks[$topindex].typename        = 'pod';       # [*-1] eventually
        @!podblocks[$topindex].style           = 'DELIMITED'; # [*-1]
        @!podblocks[$topindex].config<version> = 5;           # [*-1]
        self.set_context( 'AMBIENT' );              # issues blk_beg
    }
    method parse_p5cut { # from parse_directive
        self.set_context( 'AMBIENT' );
        my $reftopblock = pop @.blocks;
        # my PodBlock $topblock = pop @!podblocks;
        my $topblock = pop @!podblocks;
        if ( $topblock.typename ne 'pod' ) {
            # TODO: change to non fatal diagnostic
            die "=cut expected pod, got {$reftopblock<typename>}";
        }
        self.blk_end( $reftopblock );
    }

    method set_context( Str $new_context ) {
        # manages the emission of context switch function calls
        # depending on the difference between old and new context types.
        my Str $old_context = $!context;
        if ( $new_context ne $old_context ) {
            # $*ERR.say: "CONTEXT from $old_context to $new_context";
            given $old_context {
                when 'AMBIENT' { }
                when 'BLOCK_DECLARATION' {
                    my Int $topindex = @!podblocks.end;
                    self.blk_beg( @.blocks[$topindex] ); # [*-1]
                }
                when 'POD_CONTENT' {
                    my Int $topindex = @!podblocks.end;
                    my Str $style = @!podblocks[$topindex].style; # [*-1]
                    if $style eq ( 'PARAGRAPH' | 'ABBREVIATED' ) {
                        my $reftopblock = pop @.blocks;
                        # my PodBlock $top = pop @!podblocks;
                        my $top = pop @!podblocks;
                        self.blk_end( $reftopblock );
                    }
                }
                default {
                    # TODO: make better diagnostic and add unit test
                    die "unknown old context: $old_context";
                }
            }
            given $new_context {
                when 'AMBIENT' {
                    if @!podblocks {
                        my Int $topindex = @!podblocks.end;
                        if @!podblocks[$topindex].style ne 'DELIMITED' { # ABBREVIATED or POD_BLOCK
                            self.blk_end( @.blocks[$topindex] ); # [*-1]
                        }
                    }
                }
                when 'BLOCK_DECLARATION' {
                    my %newblock = (
                        'typename' => undef,
                        'style'    => undef,
                        'config'   => { }
                    );
                    # my PodBlock $newpodblock .= new(
                    my $newpodblock = PodBlock.new(
                        typename => undef,
                        style    => undef,
                        config   => { }
                    );
                    @.blocks.push( \%newblock );
                    @!podblocks.push( $newpodblock );
                }
                when 'POD_CONTENT' {
                    # if the only containing block is the outer 'pod',
                    # wrap this content in a PARAGRAPH style 'para' or 'code'
                    if @!podblocks == 1 {
                        $!codeblock = ? ( $!line ~~ /^<sp>/ ); # convert Match to Bool
                        my %newblock = (
                            'typename' => $!codeblock ?? 'code' !! 'para',
                            'style' => 'PARAGRAPH',
                            'config' => {} );
                        # my PodBlock $newpodblock .= new(
                        my $newpodblock = PodBlock.new(
                            typename => $!codeblock ?? 'code' !! 'para',
                            style    => 'PARAGRAPH',
                            config   => { }
                        );
                        self.blk_beg( %newblock );
                        @.blocks.push( \%newblock );
                        @!podblocks.push( $newpodblock );
                    }
                }
                default {
                    # TODO: make better diagnostic and add unit test
                    die "unknown new context: $old_context";
                }
            }
            $!context = $new_context;
        }
    }

    method emit( Str $text ) { $!outfile.say: $text; }

    method buf_print( Str $text ) {
        if $!buf_out_enable {
            if $text eq "\n" {
                # "\n" is an out-of-band signal for a blank line
                self.buf_flush();      # this might never be necessary
                $!buf_out_line = "\n"; # bypass margins and word wrap
                self.buf_flush();      # the "\n" to becomes emit("")
            }
            else {
                my @words = $!wrap_enable ?? $text.split(' ') !! ( $text );
                for @words -> Str $word {
                    if $!buf_out_line.chars + ($!needspace ?? 1 !! 0)
                            + $word.chars > $!margin_R {
                        self.buf_flush();
                    }
                    if $!buf_out_line.chars < $!margin_L {
                        $!buf_out_line ~=
                            ' ' x ($!margin_L - $!buf_out_line.chars);
                        $!needspace = Bool::False;
                    }
                    $!buf_out_line ~= ($!needspace ?? ' ' !! '') ~ $word;
                    $!needspace = Bool::True;
                }
            }
        }
    }

    method buf_flush {
        if $!buf_out_line ne '' {
            self.emit( ~ ( $!buf_out_line eq "\n" ?? "" !! $!buf_out_line ) );
            # why is the ~ necessary?
            $!buf_out_line = '';
            $!needspace = Bool::False;
        }
    }

    sub config( $b ) {
        my @keys = $b<config>.keys.sort; my Str $r = '';
        for @keys -> $key {
            $r ~= " $key=>{$b<config>{$key}}";
        }
        return $r;
    }
    # override these in your subclass to make a custom translator
    # ($b or $f for $refblock, $t for $text).
    method doc_beg($name){ self.emit("doc beg $name"); }
    method doc_end       { self.emit("doc end"); }

    method blk_beg($b)   { self.emit("blk beg {$b<typename>} {$b<style>}"~config($b));}
    method blk_end($b)   { self.emit("blk end {$b<typename>} {$b<style>}"); }
    method fmt_beg($f)   { self.emit("fmt beg {$f<typename>}<..."~config($f)); }
    method fmt_end($f)   { self.emit("fmt end  {$f<typename>}...>"); }
    method content($b,$t){ self.emit("content $t"); }
#   method blk_beg(PodBlock $b) { self.emit("blk beg {$b.typename} {$b.style}"~config($b));}
#   method blk_end(PodBlock $b) { self.emit("blk end {$b.typename} {$b.style}"); }
#   method fmt_beg(PodBlock $f)   { self.emit("fmt beg {$f<typename>}<..."~config($f)); }
#   method fmt_end(PodBlock $f)   { self.emit("fmt end  {$f<typename>}...>"); }
#   method content(PodBlock $b,Str $t){ self.emit("content $t"); }

    method ambient($t)   { self.emit("ambient $t"); }
    method warning($t)   { self.emit("warning $t"); }
}

class PodBlock {
    has $.typename is rw;
    has $.style    is rw;
    has %.config   is rw;
    method perl {
        my $typename = defined $.typename ?? $.typename !! 'undef';
        my $style    = defined $.style    ?? $.style    !! 'undef';
        return "( 'typename'=>'$typename', 'style'=>'$style' )";
    }
};


grammar Pod6 {
    regex directive { ^ '=' <[a..zA..Z]> }; # TODO: rewrite parse_line
    # fundamental directives 
    regex begin    { ^ '=begin' <.ws> <typename> [ <.ws> <option> ]* };
    regex end      { ^ '=end'   <.ws> <typename> };
    regex for      { ^ '=for'   <.ws> <typename> [ <.ws> <option> ]* };
    regex extra    { ^ '='                       [ <.ws> <option> ]+ };
    regex typename { code | comment | head\d+ | input | output | para | pod | table };
    # standard block types (section Blocks in order of appearance in S26)
    regex head     { ^ '=head'<level> <.ws> <heading> };
    regex para     { ^ '=para'    <.ws> <txt> };
    regex code     { ^ '=code'                   [ <.ws> <option> ]* };
    regex input    { ^ '=input'   <.ws> <txt> };
    regex output   { ^ '=output'  <.ws> <txt> };
    regex item     { ^ '=item'    <.ws> <txt> };
    regex nested   { ^ '=nested'  <.ws> <txt> };
    regex table    { ^ '=table'   <.ws> <txt> };
    regex comment  { ^ '=comment' <.ws> <txt> };
    regex END      { ^ '=END'     <.ws> <txt> };
    regex DATA     { ^ '=DATA'    <.ws> <txt> }; 
    regex semantic { <[ A..Z ]>+ };
    # other directives (pre-configuration, modules)
    regex encoding { ^ '=encoding' <.ws> <txt> };
    regex config   { ^ '=config' <.ws> <typename> [ <.ws> <option> ]* };
    regex use      { ^ '=use'      <.ws> <txt> };
    # optional backward compatibility with Perl 5 POD
    regex p5pod    { ^ '=pod'                }; # begin Perl 5 POD 
    regex p5over   { ^ '=over' <.ws> <level> }; # begin Perl 5 indent
    regex p5back   { ^ '=back'               }; # end Perl 5 indent
    regex p5cut    { ^ '=cut'                }; # end Perl 5 POD
    # building blocks
    regex txt      { .* };
    regex heading  { .+ };
    regex blank    { ^ <.ws>? $ };
    regex level    { <.digit>+ };
    regex option   { <option_false> | <option_true> | <option_string> };
    regex option_false  { ':!' <option_key> |
                          ':'  <option_key> '(' <.ws>? '0'  <.ws>? ')' |
                          ':'  <option_key> <.ws>? '=' <.gt> <.ws>? '0'
                        };
    regex option_true   {
    # problem: the next line masks option_string?
    #                     ':' <option_key> | # TODO: reinstate
                          ':' <option_key> '(' <.ws>? '1'  <.ws>? ')' |
                          ':' <option_key>     <.ws>? '=>' <.ws>?    '1'
                        };
    # would token or rule be better than regex above?
    regex option_string { ':' <option_key> <.lt> <option_value> <.gt> };
    regex option_key    { <.ident> };
    regex option_value  { .* };
}

grammar Pod6_link {
    regex TOP { <alternate> [ <ws> '|' <ws> ] ? <scheme> <external> <internal> };
    regex alternate { [ .* <?before [ <ws> '|' <ws> ] > ] ?  };
    regex scheme { [ [ http | https | file | mailto | man | doc | defn
        | isbn | issn ] ? ':' ] ? }; # TODO: non standard schemes
    regex external { [ <-[#]> + ] ? };
    regex internal { [ '#' .+ ] ? };
}

=begin pod

=head1 NAME
Pod6Parser - stream based parser for Perl 6 Plain Old Documentation

=head1 SYNOPSIS
 # in Perl 6 (Rakudo)
 use v6;
 use Pod6Parser;
 my $p = Pod6Parser.new;
 $p.parse_file( "lib/Pod/Parser.pm" );

 # in shell (one line, for testing)
 perl6 -e 'use Pod::Parser; Pod::Parser.new.parse_file(@*ARGS[0]);' Parser.pm

=head1 DESCRIPTION
This module contains the base class for of a set of POD utilities such
as L<doc:perldoc>, L<doc:pod2text> and L<doc:pod2html>.

The default Pod::Parser output is a trace of parser events and document
content to the standard output. The default output is usually converted
by a translator module to produce plain text, a Unix man page, xhtml,
Perl 5 POD or any other format.

=head2 Emitters or POD Translators (Podlators)
These are in development:
text. man (groff). xhtml. wordcount. docbook. pod5 to and from.
More are very welcome. A podchecker would also be useful.

=head1 Writing your own translator
Copy the following template and replace xxx with your format name.
Avoid names that others have published, such as text, man or xhtml.
=begin code
# Pod/to/xxx.pm
use Pod::Parser;
class Pod::to::xxx is Pod::Parser {
    method doc_beg($name){ self.emit("doc beg $name"); }
    method doc_end       { self.emit("doc end"); }
    method blk_beg($b)   { self.emit("blk beg {$b<typename>} {$b<style>}"~config($b));}
    method blk_end($b)   { self.emit("blk end {$b<typename>} {$b<style>}"); }
    method fmt_beg($f)   { self.emit("fmt beg {$f<typename>}<..."~config($f)); }
    method fmt_end($f)   { self.emit("fmt end  {$f<typename>}...>"); }
    method content($b,$t){ self.emit("content $t"); }
    method ambient($t)   { self.emit("ambient $t"); }
    method warning($t)   { self.emit("warning $t"); }
}
=end code
Add your logic, replace the "emit()" arguments and try it. Write a test
script as described in L<#DIAGNOSTICS> and verify that it works.
The simplest example is the L<Pod::to::text> translator.

=head1 METHODS

=head2 parse_file

=head2 emit

=head2 buf_print

=head2 buf_flush

=config head1 :formatted<B U> :numbered

=head1 LIMITATIONS
Auto detect of Perl 5 POD only works with a subset of valid POD5
markers.

Formatting code L<doc:links> parse incorrectly when spanned over
multiple lines.

=head1 DIAGNOSTICS
Running parse_file without an overriding translator uses the built
C<emit()> method to produce a trace of the POD parsing events.

=head2 Test suite
The t/ directory has one test script for each emitter class, except that
a single script tests both pod5 and pod6 emitters to reuse the documents.
The t/ directory also contains a document featuring each pod construct.
Each emitter test script should handle each document, therefore
$possible_tests = ( $test_scripts + 1 ) * $documents. The + 1 is because
the pod test script performs each test twice.

=head2 Round trip testing
Start with a document in one format, for example POD6. Use a translator
to generate another format such as POD5. Then use another translator to
convert the translated document back again. Compare the original and the
twice translated versions. Improve the translators (and the document)
until there are no (significant) differences.

To avoid lossy conversions the documents would only use features
available in both formats.
Therefore use different documents to test different round trips (text,
Unix man page, xhtml, docbook etc).

Success rate may improve by adding a third translation step, to the
non pod format a second time.
The outputs of the first and third translations should be identical.

=head2 Testing Coverage
General L<Helmuth von Moltke|http://en.wikipedia.org/wiki/Helmuth_von_Moltke_the_Elder>
said (translated) "no plan survives contact with the enemy".
For Pod::Parser the battle is with unexpected constructs in POD that
anyone may have written.
The fact that Pod::Parser and its emitters can pass a fixed number of
tests does not prove enough.
Certain documents do fool Pod::Parser, and it can be improved.
Everyone can help by emailing the shortest possible example of valid
misunderstood POD to the address below.
The maintainer(s) will verify the POD validity, try to alter Pod::Parser
to handle it correctly and then expand the test suite to ensure that the
problem never returns.

The Pod::Parser documentation (this POD) should contain an example of
every kind of markup to try out parsing and rendering.

The following meaningless text broadens test coverage by mentioning the
inline formatting codes that do not occur elsewhere in this document:
A<undefined> B<basis> C<code should be able to
span lines> D<definition1|synonym1> D<definition2|synonym2a;synonym2b>
E<entity> F<undefined> G<undefined> H<undefined> I<important>
J<undefined> K<keyboard input> L<http://link.url.com> M<module:content>
N<note not rendered inline> O<undefined> P<file:other.pod> Q<undefined>
R<replaceable metasyntax> S<space   preserving   text>
T<terminal output> U<unusual should be underlined>
V<verbatim does not process formatting codes> W<undefined>
X<index entry|entry1,subentry1;entry2,subentry2> Y<undefined>
Z<zero-width comment never rendered>

=head1 BUGS
Test: perl6 -e 'use Pod::Parser; Pod::Parser.new.parse_file(@*ARGS[0]);' Pod/Parser.pm
35300 good
35000 Segmentation fault
35309 Type mismatch in assignment
35477 - 35500 Segmentation fault. no output at all.
35568-35571 Could not find non-existent sub !keyword_class

Test: perl6 t/01-parser.t
35300 good
35309 Segmentation fault
35477 Method '!create' not found for invocant of class ''
35571 Lexical 'self' not found
35609 Segmentation fault

Formatting codes at the beginning or end of POD lines are not padded
with a space when word wrapped.

Formatting code L<Pod::to::whatever> parses as scheme=>Pod :(

Nested formatting codes cause internal errors.

Enums are not (yet) available for properties. A fails, B passes and C fails:
=begin code
 class A {                 has $.e is rw; method m {   $.e = 1; say $.e; }; }; A.m; # fails
 class B { enum E <X Y Z>;                method m { my $e = Y; say  $e; }; }; B.m; # works
 class C { enum E <X Y Z>; has $.e is rw; method m {   $.e = Y; say $.e; }; }; C.m; # fails
=end code

Long or complex documents randomly suffer segmentation faults.

=head1 TODO
Complete support for the full =marker set.

Handle =config and all configuration pair notations.

Manage allowed formatting codes dynamically, to support for example
=begin code
    =config C < > :allow<E I>
=end code

A handler could be added to the default case in every given { } block
to detect unhandled POD.

Calls to C<self.content()> should pass a structure of format
requirements, not a reference to a block.

Use [*-1] where possible to access the top of the Pod block stack.

Recover gracefully and issue warnings when parsing invalid or badly
formed POD.

Or.. make a pod6checker with helpful diagnostics.

Verify parser and emitters on Pugs, Mildew, Elf etc too.

=head1 SEE ALSO
L<http://perlcabal.org/syn/S26.html>
L<doc:Pod::to::man> L<doc:Pod::to::xhtml> L<doc:Pod::to::wordcount>
L<doc:perl6pod> L<doc:perl6style> The Perl 5 L<Pod::Parser>.

=head1 AUTHOR
Martin Berends (mberends on CPAN github #perl6 and @flashmail.com).

=head1 ACKNOWLEDGEMENTS
Many thanks to (in order of contribution):
Larry Wall for perl, and for letting POD be 'manpages for dummies'.
Damian Conway, for the Perl 6 POD
specification L<S26|http://perlcabal.org/syn/S26.html>.
The Rakudo developers led by Patrick Michaud and all those helpful
people on #perl6.
The Parrot developers led by chromatic and all those clever people on
#parrot.
Most recently, the "November" Wiki engine developers led by Carl Mäsak++
and Johan Viklund++, for illuminating the power and practical use of
Perl 6 regex and grammar definitions.

=end pod

