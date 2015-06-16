package Perl::Analyzer::File;
use strict;
use warnings;


sub new {
    my ($class, %args) = @_;
    
    # ensure key contains a slash so we can use the rule that
    # "if it has a slash in the name then it's not a package"
    
    my $file = $args{'file'};
    $file = "./$file" unless $file =~ m:/:;
    (my $filename = $file) =~ s/^\.//;
    
    my $self = {
        'file' => $file,
        'filename' => $filename,
        'rootdir' => $args{'rootdir'},
        'data' => {},
        'seen' => {},
        'in_pod' => undef,
        'curr_pkg' => undef,
        'curr_method' => undef,
    };
    
    bless $self, $class;
    return $self;
}


sub parse {
    my ($self) = @_;

    my $file = $self->{'file'};
    
    # go through the file and try to find out some things
    open my $fh, '<', $file or do { warn("Can't open file $file for read: $!"); return undef; };

    while (<$fh>) {
        s/\r?\n$//;
        if ($self->{'in_pod'}) {
            $self->{'in_pod'} = 0 if /^=cut/;
            next;
        }
        $self->{'in_pod'} = 1 if m/^=\w+/ && !m/^=cut/;
        last if m/^\s*__(END|DATA)__/;

        $self->parse_package($_);
        
        # skip lines which are not belong to package namespace
        next if !$self->{'curr_pkg'};
        
        # count non-empty lines
        $self->count_package_lines($_);
        
        $self->parse_sub($_);
        $self->parse_super($_);
        $self->parse_method_call($_);
        $self->parse_dependencies($_);
        $self->parse_inheritance($_, $fh);
    }
    close $fh;

    return $self->{'data'};
}


sub parse_package {
    my ($self, $line) = @_;
    # get the package name
    if ($line =~ m/^\s*package\s+([\w\:]+)\s*;/) {
        my $curr_pkg = $1;
        $self->{'curr_pkg'} = $curr_pkg;
        $self->{'data'}->{$curr_pkg} = {
            'filename'         => $self->{'filename'},
            'filerootdir'      => $self->{'rootdir'},
            'package'          => $curr_pkg,
            'line_count'       => 0,
            'depends_on'       => [],
            'parent'           => [],
            'methods'          => [],
            'methods_super'    => [],
            'methods_used'     => {},
        };
    }
}


sub count_package_lines {
    my ($self, $line) = @_;
    # get the package name
    my $curr_pkg = $self->{'curr_pkg'};
    $self->{'data'}->{$curr_pkg}->{'line_count'}++ if $line;
}


sub parse_sub {
    my ($self, $line) = @_;
    if ($line =~ m/^\s*sub\s+([\w\:]+)/) {
        my $curr_method = $1;
        $self->{'curr_method'} = $curr_method;
        $self->dpush('methods', $curr_method);
    }
}


sub parse_super {
    my ($self, $line) = @_;
    if ($line =~ m/SUPER::([\w]+)/) {
        my $super_method = $1;
        if ($super_method eq $self->{'curr_method'}) {
            # see if we call super method from here
            $self->dpush('methods_super', $super_method);
        }
    }
}


sub parse_method_call {
    # call method of another package
    my ($self, $line) = @_;
    my $curr_pkg = $self->{'curr_pkg'};
    if ($line =~ m/\s+([A-Za-z_:]+?)(::|\->)(\w+?)\(/) {
        my $package = $1;
        my $method = $3;
        if ($package !~ /^(shift|self)$/ && $method !~ /^new$/) {
            push @{ $self->{'data'}->{$curr_pkg}->{'methods_used'}->{$package} }, $method
                unless $self->{'seen'}->{$curr_pkg}->{'methods_used'}->{$package}->{$method}++;
        }
    }
}


sub parse_dependencies {
    my ($self, $line) = @_;
    
    if ($line =~ m/^\s*use\s+([\w\:]+)/) {
        $self->dpush('depends_on', $1);
    }

    if ($line =~ m/^\s*require\s+([^\s;]+)/) { # "require Bar;" or "require 'Foo/Bar.pm' if $wibble;'
        my $required = $1;
        if ($required =~ m/^([\w\:]+)$/) {
            $self->dpush('depends_on', $required);
        }
        elsif ($required =~ m/^["'](.*?\.pm)["']$/) { # simple Foo/Bar.pm case
            ($required = $1) =~ s/\.pm$//;
            $required =~ s!/!::!g;
            $self->dpush('depends_on', $required);
        }
        else {
            warn "Can't interpret $line at line $. in $self->{file}\n"
                unless m!sys/syscall.ph!
                    or m!dumpvar.pl!
                    or $required =~ /^5\./;
        }
    }
}


sub parse_inheritance {
    my ($self, $line, $fh) = @_;
    
    # the 'base/parent' pragma
    if ($line =~ m/^\s*use\s+(base|parent)\s+(.*)/) {
        require Safe;
        my $safe = new Safe;
        ( my $list = $2 ) =~ s/\s+\#.*//;
        $list =~ s/[\r\n]//;
        while ( $list !~ /;\s*$/ && ( $_ = <$fh> ) ) {
            s/\s+#.*//;
            s/[\r\n]//;
            $list .= $_;
        }
        $list =~ s/;\s*$//;
        my (@mods) = $safe->reval($list);
        warn "Unable to eval $line at line $. in $self->{file}: $@\n" if $@;
        foreach my $mod (@mods) {
            $self->dpush('parent', $mod);
        }
    }
}


sub dpush {
    my ($self, $key, $value) = @_;
    my $curr_pkg = $self->{'curr_pkg'};
    push @{ $self->{'data'}->{$curr_pkg}->{$key} }, $value
        unless $self->{'seen'}->{$curr_pkg}->{$key}->{$value}++;
}

=for

Based on Module::Dependency by Tim Bunce and P Kent.

=cut
1;