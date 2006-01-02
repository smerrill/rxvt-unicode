/*----------------------------------------------------------------------*
 * File:	rxvtperl.xs
 *----------------------------------------------------------------------*
 *
 * All portions of code are copyright by their respective author/s.
 * Copyright (c) 2005-2005 Marc Lehmann <pcg@goof.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 *----------------------------------------------------------------------*/

#define line_t perl_line_t
#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>
#undef line_t

#include "../config.h"

#include <cstdarg>

#include "rxvt.h"
#include "iom.h"
#include "rxvtutil.h"
#include "rxvtperl.h"

#include "perlxsi.c"

/////////////////////////////////////////////////////////////////////////////

static wchar_t *
sv2wcs (SV *sv)
{
  STRLEN len;
  char *str = SvPVutf8 (sv, len);
  return rxvt_utf8towcs (str, len);
}

static SV *
new_ref (HV *hv, const char *klass)
{
  return sv_bless (newRV ((SV *)hv), gv_stashpv (klass, 1));
}

//TODO: use magic
static SV *
newSVptr (void *ptr, const char *klass)
{
  HV *hv = newHV ();
  hv_store (hv, "_ptr", 4, newSViv ((long)ptr), 0);
  return sv_bless (newRV_noinc ((SV *)hv), gv_stashpv (klass, 1));
}

static long
SvPTR (SV *sv, const char *klass)
{
  if (!sv_derived_from (sv, klass))
    croak ("object of type %s expected", klass);

  IV iv = SvIV (*hv_fetch ((HV *)SvRV (sv), "_ptr", 4, 1));

  if (!iv)
    croak ("perl code used %s object, but C++ object is already destroyed, caught", klass);

  return (long)iv;
}

#define newSVterm(term) SvREFCNT_inc ((SV *)term->self)
#define SvTERM(sv) (rxvt_term *)SvPTR (sv, "urxvt::term")

/////////////////////////////////////////////////////////////////////////////

struct perl_watcher
{
  SV *cbsv;
  HV *self;

  perl_watcher ()
  : cbsv (newSV (0))
  {
  }

  ~perl_watcher ()
  {
    SvREFCNT_dec (cbsv);
  }

  void cb (SV *cb)
  {
    sv_setsv (cbsv, cb);
  }

  void invoke (const char *type, SV *self, int arg = -1);
};

void
perl_watcher::invoke (const char *type, SV *self, int arg)
{
  dSP;

  ENTER;
  SAVETMPS;

  PUSHMARK (SP);

  XPUSHs (sv_2mortal (self));

  if (arg >= 0)
    XPUSHs (sv_2mortal (newSViv (arg)));

  PUTBACK;
  call_sv (cbsv, G_VOID | G_EVAL | G_DISCARD);
  SPAGAIN;

  PUTBACK;
  FREETMPS;
  LEAVE;

  if (SvTRUE (ERRSV))
    rxvt_warn ("%s callback evaluation error: %s", type, SvPV_nolen (ERRSV));
}

#define newSVtimer(timer) new_ref (timer->self, "urxvt::timer")
#define SvTIMER(sv) (timer *)SvPTR (sv, "urxvt::timer")

struct timer : time_watcher, perl_watcher
{
  timer ()
  : time_watcher (this, &timer::execute)
  {
  }

  void execute (time_watcher &w)
  {
    invoke ("urxvt::timer", newSVtimer (this));
  }
};

#define newSViow(iow) new_ref (iow->self, "urxvt::iow")
#define SvIOW(sv) (iow *)SvPTR (sv, "urxvt::iow")

struct iow : io_watcher, perl_watcher
{
  iow ()
  : io_watcher (this, &iow::execute)
  {
  }

  void execute (io_watcher &w, short revents)
  {
    invoke ("urxvt::iow", newSViow (this), revents);
  }
};

/////////////////////////////////////////////////////////////////////////////

struct rxvt_perl_interp rxvt_perl;

static PerlInterpreter *perl;

rxvt_perl_interp::rxvt_perl_interp ()
{
}

rxvt_perl_interp::~rxvt_perl_interp ()
{
  if (perl)
    {
      perl_destruct (perl);
      perl_free (perl);
    }
}

void
rxvt_perl_interp::init ()
{
  if (!perl)
    {
      char *argv[] = {
        "",
        "-edo '" LIBDIR "/urxvt.pm' or ($@ and die $@) or exit 1",
      };

      perl = perl_alloc ();
      perl_construct (perl);

      if (perl_parse (perl, xs_init, 2, argv, (char **)NULL)
          || perl_run (perl))
        {
          rxvt_warn ("unable to initialize perl-interpreter, continuing without.\n");

          perl_destruct (perl);
          perl_free (perl);
          perl = 0;
        }
    }
}

bool
rxvt_perl_interp::invoke (rxvt_term *term, hook_type htype, ...)
{
  if (!perl)
    return false;

  if (htype == HOOK_INIT) // first hook ever called
    term->self = (void *)newSVptr ((void *)term, "urxvt::term");
  else if (htype == HOOK_DESTROY)
    {
      // TODO: clear magic
      hv_clear ((HV *)SvRV ((SV *)term->self));
      SvREFCNT_dec ((SV *)term->self);
    }

  if (!should_invoke [htype])
    return false;
  
  dSP;
  va_list ap;

  va_start (ap, htype);

  ENTER;
  SAVETMPS;

  PUSHMARK (SP);

  XPUSHs (sv_2mortal (newSVterm (term)));
  XPUSHs (sv_2mortal (newSViv (htype)));

  for (;;) {
    data_type dt = (data_type)va_arg (ap, int);

    switch (dt)
      {
        case DT_INT:
          XPUSHs (sv_2mortal (newSViv (va_arg (ap, int))));
          break;

        case DT_LONG:
          XPUSHs (sv_2mortal (newSViv (va_arg (ap, long))));
          break;

        case DT_END:
          {
            va_end (ap);

            PUTBACK;
            int count = call_pv ("urxvt::invoke", G_ARRAY | G_EVAL);
            SPAGAIN;

            if (count)
              {
                SV *status = POPs;
                count = SvTRUE (status);
              }

            PUTBACK;
            FREETMPS;
            LEAVE;

            if (SvTRUE (ERRSV))
              rxvt_warn ("perl hook %d evaluation error: %s", htype, SvPV_nolen (ERRSV));

            return count;
          }

        default:
          rxvt_fatal ("FATAL: unable to pass data type %d\n", dt);
      }
  }
}

/////////////////////////////////////////////////////////////////////////////

MODULE = urxvt             PACKAGE = urxvt

PROTOTYPES: ENABLE

BOOT:
{
# define set_hookname(sym) av_store (hookname, PP_CONCAT(HOOK_, sym), newSVpv (PP_STRINGIFY(sym), 0))
  AV *hookname = get_av ("urxvt::HOOKNAME", 1);
  set_hookname (LOAD);
  set_hookname (INIT);
  set_hookname (RESET);
  set_hookname (START);
  set_hookname (DESTROY);
  set_hookname (SEL_BEGIN);
  set_hookname (SEL_EXTEND);
  set_hookname (SEL_MAKE);
  set_hookname (SEL_GRAB);
  set_hookname (FOCUS_IN);
  set_hookname (FOCUS_OUT);
  set_hookname (VIEW_CHANGE);
  set_hookname (SCROLL_BACK);
  set_hookname (TTY_ACTIVITY);
  set_hookname (REFRESH_BEGIN);
  set_hookname (REFRESH_END);

  sv_setpv (get_sv ("urxvt::LIBDIR", 1), LIBDIR);
}

void
set_should_invoke (int htype, int value)
	CODE:
        rxvt_perl.should_invoke [htype] = value;

void
warn (const char *msg)
	CODE:
        rxvt_warn ("%s", msg);

void
fatal (const char *msg)
	CODE:
        rxvt_fatal ("%s", msg);

int
wcswidth (SV *str)
	CODE:
{
        wchar_t *wstr = sv2wcs (str);
        RETVAL = wcswidth (wstr, wcslen (wstr));
        free (wstr);
}
	OUTPUT:
        RETVAL

NV
NOW ()
	CODE:
        RETVAL = NOW;
        OUTPUT:
        RETVAL

MODULE = urxvt             PACKAGE = urxvt::term

void
rxvt_term::selection_mark (...)
	PROTOTYPE: $;$$
        ALIAS:
           selection_beg = 1
           selection_end = 2
        PPCODE:
{
        row_col_t &sel = ix == 1 ? THIS->selection.beg
                       : ix == 2 ? THIS->selection.end
                       :           THIS->selection.mark;

        if (GIMME_V != G_VOID)
          {
            EXTEND (SP, 2);
            PUSHs (sv_2mortal (newSViv (sel.row)));
            PUSHs (sv_2mortal (newSViv (sel.col)));
          }

        if (items == 3)
          {
            sel.row = clamp (SvIV (ST (1)), -THIS->nsaved, THIS->nrow - 1);
            sel.col = clamp (SvIV (ST (2)), 0, THIS->ncol - 1);

            if (ix)
              THIS->want_refresh = 1;
          }
}

int
rxvt_term::selection_grab (int eventtime)

void
rxvt_term::selection (SV *newtext = 0)
        PPCODE:
{
        if (GIMME_V != G_VOID)
          {
            char *sel = rxvt_wcstoutf8 (THIS->selection.text, THIS->selection.len);
            SV *sv = newSVpv (sel, 0);
            SvUTF8_on (sv);
            free (sel);
            XPUSHs (sv_2mortal (sv));
          }

        if (newtext)
          {
            free (THIS->selection.text);

            THIS->selection.text = sv2wcs (newtext);
            THIS->selection.len = wcslen (THIS->selection.text);
          }
}
        
void
rxvt_term::scr_overlay_new (int x, int y, int w, int h)

void
rxvt_term::scr_overlay_off ()

void
rxvt_term::scr_overlay_set_char (int x, int y, U32 text, U32 rend = OVERLAY_RSTYLE)
	CODE:
        THIS->scr_overlay_set (x, y, text, rend);

void
rxvt_term::scr_overlay_set (int x, int y, SV *text)
	CODE:
{
        wchar_t *wtext = sv2wcs (text);
        THIS->scr_overlay_set (x, y, wtext);
        free (wtext);
}

MODULE = urxvt             PACKAGE = urxvt::timer

SV *
timer::new ()
	CODE:
        timer *w =  new timer;
        RETVAL = newSVptr ((void *)w, "urxvt::timer");
        w->self = (HV *)SvRV (RETVAL);
        OUTPUT:
        RETVAL

timer *
timer::cb (SV *cb)
	CODE:
        THIS->cb (cb);
        RETVAL = THIS;
        OUTPUT:
        RETVAL

NV
timer::at ()
	CODE:
        RETVAL = THIS->at;
        OUTPUT:
        RETVAL

timer *
timer::set (NV tstamp)
	CODE:
        THIS->set (tstamp);
        RETVAL = THIS;
        OUTPUT:
        RETVAL

timer *
timer::start (NV tstamp = THIS->at)
        CODE:
        THIS->start (tstamp);
        RETVAL = THIS;
        OUTPUT:
        RETVAL

timer *
timer::stop ()
	CODE:
        THIS->stop ();
        RETVAL = THIS;
        OUTPUT:
        RETVAL

void
timer::DESTROY ()

MODULE = urxvt             PACKAGE = urxvt::iow

SV *
iow::new ()
	CODE:
        iow *w =  new iow;
        RETVAL = newSVptr ((void *)w, "urxvt::iow");
        w->self = (HV *)SvRV (RETVAL);
        OUTPUT:
        RETVAL

iow *
iow::cb (SV *cb)
	CODE:
        THIS->cb (cb);
        RETVAL = THIS;
        OUTPUT:
        RETVAL

iow *
iow::fd (int fd)
	CODE:
        THIS->fd = fd;
        RETVAL = THIS;
        OUTPUT:
        RETVAL

iow *
iow::events (short events)
	CODE:
        THIS->events = events;
        RETVAL = THIS;
        OUTPUT:
        RETVAL

iow *
iow::start ()
        CODE:
        THIS->start ();
        RETVAL = THIS;
        OUTPUT:
        RETVAL

iow *
iow::stop ()
	CODE:
        THIS->stop ();
        RETVAL = THIS;
        OUTPUT:
        RETVAL

void
iow::DESTROY ()

