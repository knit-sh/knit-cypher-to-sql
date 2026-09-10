#                                               -*- Autoconf -*-
# Process this file with autoconf to produce a configure script.

AC_PREREQ([2.71])
# The version is kept in the top-level VERSION file and read here at autoreconf
# time (m4_esyscmd_s strips the trailing newline).
AC_INIT([knit-cypher-to-sql],[m4_esyscmd_s([cat VERSION])],[https://github.com/knit-sh/knit-cypher-to-sql])
AC_CONFIG_AUX_DIR([build-aux])
AC_CONFIG_MACRO_DIR([m4])
AC_CONFIG_SRCDIR([src/main.c])
AC_CONFIG_HEADERS([config.h])
AM_INIT_AUTOMAKE([foreign subdir-objects -Wall])

# Programs.
AC_PROG_CC

# Grammar tooling for the bundled parser/scanner. A release tarball ships the
# generated sources, so an end user builds with only a C compiler; these are
# needed only from a git checkout.
AC_PROG_YACC
AC_PROG_LEX([noyywrap])

# The transpiler links nothing beyond libc: it does not open a database or run
# a query, so it needs no SQLite headers or library.

# Optional coverage instrumentation (--enable-coverage).
AC_ARG_ENABLE([coverage],
  [AS_HELP_STRING([--enable-coverage],[build with gcov coverage instrumentation])],
  [enable_coverage=$enableval],[enable_coverage=no])
AS_IF([test "x$enable_coverage" = "xyes"],
  [COVERAGE_CFLAGS="--coverage -O0 -g"
   COVERAGE_LDFLAGS="--coverage"])
AC_SUBST([COVERAGE_CFLAGS])
AC_SUBST([COVERAGE_LDFLAGS])

AC_CONFIG_FILES([Makefile src/Makefile tests/Makefile])
AC_OUTPUT
