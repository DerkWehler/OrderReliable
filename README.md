# OrderReliable
An open-source (GNU license) library for MT4 expert advisers.
From the header:
A library for MT4 expert advisers, intended to give more reliable order handling.	This library only concerns the mechanics of sending orders to the Metatrader server, dealing with transient connectivity problems better than the standard order sending functions.  It is essentially an error-checking wrapper around the existing transaction functions. This library provides nothing to help actual trade strategies, but ought to be valuable for nearly all expert advisers which trade 'live'.

17 June, 2020: Added "ERR_MARKET_CLOSED" to list of retryable errors.  Made changes to [mostly] debug lines so that one no longer gets compiler warnings when using "use strict".  Please let me know if you have any problems.
