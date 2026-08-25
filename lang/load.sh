# Message loader, sourced by the interactive scripts.
#
# Every script defines its messages in English inline, then sources this file.
# With FANCTL_LANG set to a language that exists in this directory, the matching
# file is sourced on top and overrides whatever it defines. Unset — or set to
# something with no file here — leaves the English defaults untouched, so a
# missing or partial translation degrades to English rather than to blanks.
#
#   FANCTL_LANG=uk sudo ./install.sh
#
# Messages that interpolate values are printf format strings; a translation must
# keep the same conversions in the same order.
#
# Deliberately not driven by LANG/LC_ALL: a Ukrainian locale is a statement
# about dates and sorting, not a request for this installer to change language
# on someone who has been reading its English docs.

_fanctl_lang_dir=${_fanctl_lang_dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

if [ -n "${FANCTL_LANG:-}" ]; then
    if [ -r "$_fanctl_lang_dir/${FANCTL_LANG}.sh" ]; then
        . "$_fanctl_lang_dir/${FANCTL_LANG}.sh"
    else
        echo "FANCTL_LANG=${FANCTL_LANG}: no ${FANCTL_LANG}.sh in $_fanctl_lang_dir, using English" >&2
    fi
fi
