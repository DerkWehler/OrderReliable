//=============================================================================
//                              OrderReliable.mqh
//
//         Copyright © 2006, Derk Wehler     (derkwehler@gmail.com)
//
//  This file is simply LibOrderReliable as a header file instead of a library
//
//  In order to read this code most clearly in the Metaeditor, it is advised
//  that you set your tab settings to 4 (instead of the default 3): 
//  Tools->Options->General Tab, set Tab Size to 4, uncheck "Insert spaces"
//
// ***************************************************************************
// ***************************************************************************
//
//  LICENSING:  This is free, open source software, licensed under
//              Version 3 of the GNU General Public License (GPL).
//
//  A library for MT4 expert advisers, intended to give more reliable
//  order handling.	This library only concerns the mechanics of sending
//  orders to the Metatrader server, dealing with transient connectivity
//  problems better than the standard order sending functions.  It is
//  essentially an error-checking wrapper around the existing transaction
//  functions. This library provides nothing to help actual trade strategies,
//  but ought to be valuable for nearly all expert advisers which trade 'live'.
//
//
//=============================================================================
//
//  Contents:
//
//		OrderSendReliable()
//			This is intended to be a drop-in replacement for OrderSend()
//			which, one hopes is more resistant to various forms of errors
//			prevalent with MetaTrader.
//
//		OrderSendReliableMKT()
//			This function is intended for immediate market-orders ONLY,
//			the principal difference that in its internal retry-loop,
//			it uses the new "Bid" and "Ask" real-time variables as opposed
//			to the OrderSendReliable() which uses only the price given upon
//			entry to the routine.  More likely to get off orders, and more
//			likely they are further from desired price.
//
//		OrderSendReliable2Step()
//			This function is intended to be used when brokers do not allow
//			initial stoploss and take-profit settings as part of the initial
//			market order. After successfully playing an order, it will then
//			Call OrderModifyReliable() to update the SL and TP settings.
//
//		OrderModifyReliable()
//			A replacement for OrderModify with more error handling.
//
//		OrderCloseReliable()
//			A replacement for OrderClose with more error handling.
//
//		OrderCloseReliableMKT()
//			This function is intended for closing orders ASAP; the
//			principal difference is that in its internal retry-loop,
//			it uses the new "Bid" and "Ask" real-time variables as opposed
//			to the OrderCloseReliable() which uses only the price given upon
//			entry to the routine.  More likely to get the order closed if 
//          price moves, but more likely to "slip"
//
//		OrderDeleteReliable()
//			A replacement for OrderDelete with more error handling.
//
//===========================================================================
//                      CHANGE LOG BEGUN 28 March, 2014
//         Prior to this, Source OffSite was used to save changes
//      Start with revision 32, which is what SOS had as last change
//
//  v32, 28Mar14: 
//  Small bug fixes for Build 600 changes
//
//  v33, 25Apr16: 
//  Tiny adjustment made to GetOrderDetails() for non-forex pairs
//
//  v34, 21Jun16: 
//  Changed SleepRandomTime() to just sleep 200ms
//
//  v35, 20Jul16: (important)
//  Added MySymbolConst2Val(), MySymbolVal2String(), necessary for correct
//  functioning of GetOrderDetails()
//
//  v36, 30Nov18:
//  Changed logging statements format
//  Changed all outer scope vars to "g.." format
//  Changed orRetryAttempts to 5 (was 10)
//
//  v37, 5Aug19:
//  Changed OrderReliablePrint to take calling function name as 1st param
//  Reprogrammed SleepRandomTime() to be less cryptic. Added SleepAveTime, 
//  set to 50ms. Got rid of gSleepTime & gSleepMaximum.
//
//  v38, 26Mar20:
//  For the add spread to comment, reduced by 2 chars, cause not much room
//
//  v39, 15Jun20:
//  Cleaned up all the compiler warnings that appear with 
//  "#property use strict", For all the strict sissies out there (j/k) ;-)
//  Hope I didn't break much.... Also added	this line various places:
//
//      case ERR_MARKET_CLOSED:	// Added 16Jun20
//
//  v40, 03Sep20:
//	Replaced (int)MarketInfo(symbol, MODE_DIGITS) with 'digits' in a couple 
//	places in EnsureValidStops(). Not a functional change.  Made some 
//	changes to GetOrderDetails() in handling a situation where digits == 0.
//	More importantly, if point comes back as zero, because this would cause 
//	divide-by-zero crashes.  Went through code and checked for this zero 
//	condition and avoided.  But if point == 0, the order is still somewhat 
//	likely tbe be problematic.
//
//  v41, 21Sep20:
//	Saw slippage on stops: changed 'if (slipped > 0)' to 'if (slipped != 0)' 
//	in OrderSendReliable2Step(). This WAS indeed a bug.  For buys, if 
//	slipped < 0 it means you got in at a better price, so the benefits of 
//	moving the stops may be debatable, but for a sell, slipped < 0 means 
//	you got in on a worse price...
//
//	Updated MySymbolVal2String() and MySymbolConst2Val() with versions more 
//	functional with non-forex pairs.  Added global or NonStandardSymbol.
//	Changed globals to be prefaced with "or". 
//
//  v42, 27Aug21:
//	Did a lot of refactoring in switch statements; not much functionally 
//	different, but hopefully some improvements -changed trade disabled and 
//	market closed to be non-retryable errors.
//
//===========================================================================

#property copyright "Copyright © 2006, Derk Wehler"
#property link      "derkwehler@gmail.com"

#include <stdlib.mqh>
#include <stderror.mqh>

string 	OrderReliableVersion = "v42";

int 	orRetryAttempts			= 5;
double 	orSleepAveTime			= 50.0;

int 	orErrorLevel 			= 3;

bool	orUseLimitToMarket		= false;
bool	orUseForTesting 		= false;
bool	orAddSpreadToComment	= false;
bool	orNonStandardSymbol		= false;

//=============================================================================
//							 OrderSendReliable()
//
//  This is intended to be a drop-in replacement for OrderSend() which,
//  one hopes, is more resistant to various forms of errors prevalent
//  with MetaTrader.
//
//	RETURN VALUE:
//     Ticket number or -1 under some error conditions.  
//
//  FEATURES:
//     * Re-trying under some error conditions, sleeping a random
//       time defined by an exponential probability distribution.
//
//     * Automatic normalization of Digits
//
//     * Automatically makes sure that stop levels are more than
//       the minimum stop distance, as given by the server. If they
//       are too close, they are adjusted.
//
//     * Automatically converts stop orders to market orders
//       when the stop orders are rejected by the server for
//       being to close to market.  NOTE: This intentionally
//       applies only to OP_BUYSTOP and OP_SELLSTOP,
//       OP_BUYLIMIT and OP_SELLLIMIT are not converted to market
//       orders and so for prices which are too close to current
//       this function is likely to loop a few times and return
//       with the "invalid stops" error message.
//       Note, the commentary in previous versions erroneously said
//       that limit orders would be converted.  Note also
//       that entering a BUYSTOP or SELLSTOP new order is distinct
//       from setting a stoploss on an outstanding order; use
//       OrderModifyReliable() for that.
//
//     * Displays various error messages on the log for debugging.
//
//  ORIGINAL AUTHOR AND DATE:
//     Matt Kennel, 2006-05-28
//
//=============================================================================
int OrderSendReliable(string symbol, int cmd, double volume, double price,
                      int slippage, double stoploss, double takeprofit,
                      string comment="", int magic=0, datetime expiration=0,
                      color arrow_color=CLR_NONE)
{
	string fn = __FUNCTION__ + "[]";

	int ticket = -1;
	bool nonRetryableError = false;
	bool skipSleep = false;

	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!orUseForTesting)
	{
		if (IsOptimization()  ||  IsTesting())
		{
			ticket = OrderSend(symbol, cmd, volume, price, slippage, stoploss,
			                   takeprofit, comment, magic, expiration, arrow_color);
			return(ticket);
		}
	}
	// ========================================================================
	
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	// Get information about this order
	double realPoint = MarketInfo(symbol, MODE_POINT);
	double adjPoint = realPoint;
	if (adjPoint == 0.00001  ||  adjPoint == 0.001)
		adjPoint *= 10;
	int digits;
	double point;
	double bid, ask;
	double sl, tp;
	double priceNow = 0;
	double hasSlippedBy = 0;
	
	GetOrderDetails(0, symbol, cmd, digits, point, sl, tp, bid, ask, false);
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	
	OrderReliablePrint(fn, "");
	OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
	OrderReliablePrint(fn, "Attempted " + OrderTypeToString(cmd) + " " + symbol + ": " + DoubleToStr(volume, 3) + " lots @" + 
	                   DoubleToStr(price, digits) + ", sl:" + DoubleToStr(stoploss, digits) + ", tp:" + DoubleToStr(takeprofit, digits));


	// Normalize all price / stoploss / takeprofit to the proper # of digits.
	price = NormalizeDouble(price, digits);
	stoploss = NormalizeDouble(stoploss, digits);
	takeprofit = NormalizeDouble(takeprofit, digits);

	// Check stop levels, adjust if necessary
	EnsureValidStops(symbol, cmd, price, stoploss, takeprofit);

	int cnt;
	GetLastError(); // clear the global variable.
	int err = 0;
	bool exitLoop = false;
	bool limit_to_market = false;
	bool fixed_invalid_price = false;

	// Concatenate to comment if enabled
	double symSpr = MarketInfo(symbol, MODE_ASK) - MarketInfo(symbol, MODE_BID);
	if (orAddSpreadToComment)
		comment = comment + ", Spr:" + DoubleToStr(symSpr / adjPoint, 1);
		
	// Limit/Stop order...............................................................
	if (cmd > OP_SELL)
	{
		cnt = 0;
		while (!exitLoop)
		{
			skipSleep = false;
			
			// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =
			// Calculating our own slippage internally should not need to be done for pending orders; see market orders below
			// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =

			//OrderReliablePrint(fn, "About to call OrderSend(), comment = " + comment);
			ticket = OrderSend(symbol, cmd, volume, price, slippage, stoploss,
			                   takeprofit, comment, magic, expiration, arrow_color);
			err = GetLastError();

			switch (err)
			{
				// No error
				case ERR_NO_ERROR:
					OrderReliablePrint(fn, "ERR_NO_ERROR received, but OrderSend() still returned false; exiting");
					exitLoop = true;
					break;

				// Non-retryable error
				case ERR_TRADE_DISABLED:
				case ERR_MARKET_CLOSED:
				case ERR_INVALID_TRADE_PARAMETERS:
					nonRetryableError = true;
					exitLoop = true;
					break;

				// retryable errors
				case ERR_PRICE_CHANGED:
				case ERR_REQUOTE:
					skipSleep = true;			// we can apparently retry immediately according to MT docs (so no sleep)
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_TRADE_CONTEXT_BUSY:
				case ERR_TRADE_TIMEOUT:
					cnt++;
					break;

				case ERR_INVALID_PRICE:
				case ERR_INVALID_STOPS:
					limit_to_market = EnsureValidPendPrice(err, fixed_invalid_price, symbol, cmd, price, 
														   stoploss, takeprofit, slippage, point, digits);
					if (limit_to_market) 
						exitLoop = true;
					cnt++;
					break;

				default:	// an apparently serious error.
					OrderReliablePrint(fn, "Unknown error occured: " + err);
					nonRetryableError = true;
					exitLoop = true;
					break;

			}  // end switch

			if (cnt > orRetryAttempts)
				exitLoop = true;

			if (exitLoop)
			{
				if (!limit_to_market)
				{
					if (nonRetryableError)
						OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
					else if (cnt > orRetryAttempts)
						OrderReliablePrint(fn, "Retry attempts maxed at " + IntegerToString(orRetryAttempts));
				}
				break;
			}
			else
			{
				OrderReliablePrint(fn, "Result of attempt " + IntegerToString(cnt) + " of " + IntegerToString(orRetryAttempts) + ": Retryable error: " + OrderReliableErrTxt(err));
				OrderReliablePrint(fn, "Current Bid = " + DoubleToStr(MarketInfo(symbol, MODE_BID), digits) + ", Current Ask = " + DoubleToStr(MarketInfo(symbol, MODE_ASK), digits));
				OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
				if (!skipSleep)
					SleepRandomTime();
				RefreshRates();
			}
		}

		// We have now exited from loop.
		if (err == ERR_NO_ERROR  ||  err == ERR_NO_RESULT)
		{
			OrderReliablePrint(fn, "Ticket #" + IntegerToString(ticket) + ": Successful " + OrderTypeToString(cmd) + " order placed with comment = " + comment + ", details follow.");
			if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
				OrderReliablePrint(fn, "Could Not Select Ticket #" + IntegerToString(ticket));
			OrderPrint();
			OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
			OrderReliablePrint(fn, "");
			return(ticket); // SUCCESS!
		}
		if (!limit_to_market)
		{
			if (cnt > 0)
				OrderReliablePrint(fn, "Failed to execute stop or limit order after " + IntegerToString(cnt-1) + " retries");
			OrderReliablePrint(fn, "Failed trade: " + OrderTypeToString(cmd) + ", " + DoubleToStr(volume, 2) + " lots,  " + symbol +
			                   "@" + DoubleToStr(price, digits) + ", sl@" + DoubleToStr(stoploss, digits) + ", tp@" + DoubleToStr(takeprofit, digits));
			OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
			OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
			OrderReliablePrint(fn, "");
			return(-1);
		}
	}  // end

	if (limit_to_market)
	{
		OrderReliablePrint(fn, "Going from stop/limit order to market order because market is too close.");
		cmd %= 2;
	}

	// We now have a market order.
	err = GetLastError(); // so we clear the global variable.
	err = 0;
	ticket = -1;
	exitLoop = false;
	nonRetryableError = false;


	// Market order..........................................................
	if (cmd == OP_BUY  ||  cmd == OP_SELL)
	{
		cnt = 0;
		while (!exitLoop)
		{
			skipSleep = false;
			
			// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =
			// Get current price and calculate slippage
			if (point != 0)
			{
				if (cmd == OP_BUY)
				{
					priceNow = NormalizeDouble(MarketInfo(symbol, MODE_ASK), (int)MarketInfo(symbol, MODE_DIGITS));	// Open @ Ask
					hasSlippedBy = (priceNow - price) / point;	// (Adjusted Point)
				}
				else if (cmd == OP_SELL)
				{
					priceNow = NormalizeDouble(MarketInfo(symbol, MODE_BID), (int)MarketInfo(symbol, MODE_DIGITS));	// Open @ Bid
					hasSlippedBy = (price - priceNow) / point;	// (Adjusted Point)
				}
			}

			// Check if slippage is more than caller's maximum allowed
			if (priceNow != price  &&  hasSlippedBy > slippage)
			{
				// Actual price has slipped against us more than user allowed
				// Log error message, sleep, and try again
				OrderReliablePrint(fn, "Actual Price (Ask for buy, Bid for sell) = " + DoubleToStr(priceNow, Digits+1) + "; Slippage from Requested Price = " + DoubleToStr(hasSlippedBy, 1) + " pips.  Retrying...");
				err = ERR_PRICE_CHANGED;
			}
			else
			{
				if (priceNow != price)
				{
					// If the price has slipped "acceptably" (either negative or within 
					// "Slippage" param), then we need to adjust the SL and TP accordingly
					double M = (cmd == OP_BUY) ? 1.0 : -1.0;
					if (stoploss != 0)		stoploss += M * hasSlippedBy;
					if (takeprofit != 0)	takeprofit += M * hasSlippedBy;
					
					// Price may move again while we try this order. Must adjust Spippage by amount already slipped
					slippage -= hasSlippedBy;
					OrderReliablePrint(fn, "Actual Price (Ask for buy, Bid for sell) = " + DoubleToStr(priceNow, Digits+1) + "; Requested Price = " + DoubleToStr(price, Digits) + "; Slippage from Requested Price = " + DoubleToStr(hasSlippedBy, 1) + " pips (\'positive slippage\').  Attempting order at market");
				}
				//OrderReliablePrint(fn, "About to call OrderSend(), comment = " + comment);
				ticket = OrderSend(symbol, cmd, volume, priceNow, (int)(slippage - hasSlippedBy), 
								   stoploss, takeprofit, comment, magic,	expiration, arrow_color);
				err = GetLastError();
			}
			// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =

			// Exclusively for debugging
			if (err == ERR_NO_ERROR)
				OrderReliablePrint(fn, "ERR_NO_ERROR received, but OrderSend() still returned false; exiting");
			else if (err == ERR_INVALID_PRICE)
			{
				if (cmd == OP_BUY)
					OrderReliablePrint(fn, "INVALID PRICE ERROR - Requested Price: " + DoubleToStr(price, Digits) + "; Ask = " + DoubleToStr(MarketInfo(symbol, MODE_ASK), Digits));
				else
					OrderReliablePrint(fn, "INVALID PRICE ERROR - Requested Price: " + DoubleToStr(price, Digits) + "; Bid = " + DoubleToStr(MarketInfo(symbol, MODE_BID), Digits));
			}
			else if (err == ERR_INVALID_STOPS)
				OrderReliablePrint(fn, "INVALID STOPS on attempted " + OrderTypeToString(cmd) + " : " + DoubleToStr(volume, 2) + " lots " + " @ " + DoubleToStr(price, Digits) + ", SL = " + DoubleToStr(stoploss, Digits) + ", TP = " + DoubleToStr(takeprofit, Digits));
				
			switch (err)
			{
				// No error
				case ERR_NO_ERROR:
					exitLoop = true;
					break;
					
				// Non-retryable error
				case ERR_TRADE_DISABLED:
				case ERR_MARKET_CLOSED:
					nonRetryableError = true;
					exitLoop = true;
					break;

				// Retryable error
				case ERR_INVALID_PRICE:
				case ERR_INVALID_STOPS:
					skipSleep = true;			// we can apparently retry immediately according to MT docs (so no sleep)
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_TRADE_CONTEXT_BUSY:
				case ERR_TRADE_TIMEOUT:
				case ERR_PRICE_CHANGED:
				case ERR_REQUOTE:
					cnt++;
					break;

				default:	// an apparently serious, unretryable error.
					OrderReliablePrint(fn, "Unknown error occured: " + err);
					nonRetryableError = true;
					exitLoop = true;
					break;
			}  

			if (cnt > orRetryAttempts)
				exitLoop = true;

			if (exitLoop)
			{
				if (err != ERR_NO_ERROR  &&  err != ERR_NO_RESULT)
					OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
				if (cnt > orRetryAttempts)
					OrderReliablePrint(fn, "Retry attempts maxed at " + IntegerToString(orRetryAttempts));
				break;
			}
			else
			{
				OrderReliablePrint(fn, "Result of attempt " + IntegerToString(cnt) + " of " + IntegerToString(orRetryAttempts) + ": Retryable error: " + OrderReliableErrTxt(err));
				OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
				if (!skipSleep)
					SleepRandomTime();
				RefreshRates();
			}
		}

		// We have now exited from loop; if successful, return ticket #
		if (err == ERR_NO_ERROR  ||  err == ERR_NO_RESULT)
		{
			OrderReliablePrint(fn, "Ticket #" + IntegerToString(ticket) + ": Successful " + OrderTypeToString(cmd) + " order placed with comment = " + comment + ", details follow.");
			if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
				OrderReliablePrint(fn, "Could Not Select Ticket #" + IntegerToString(ticket));
			OrderPrint();
			OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
			OrderReliablePrint(fn, "");
			return(ticket); // SUCCESS!
		}
		
		// If not successful, log and return -1
		if (cnt > 0)
			OrderReliablePrint(fn, "Failed to execute OP_BUY/OP_SELL, after " + IntegerToString(cnt-1) + " retries");
		OrderReliablePrint(fn, "Failed trade: " + OrderTypeToString(cmd) + " " + DoubleToStr(volume, 2) + " lots  " + symbol +
		                   "@" + DoubleToStr(price, digits) + " tp@" + DoubleToStr(takeprofit, digits) + " sl@" + DoubleToStr(stoploss, digits));
		OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
		OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
		OrderReliablePrint(fn, "");
	}
	return(-1);
}

/*
//=============================================================================
//							 OrderSendReliableMKT()
//
//  This is intended to be an alternative for OrderSendReliable() which
//  will update market-orders in the retry loop with the current Bid or Ask.
//  Hence with market orders there is a greater likelihood that the trade will
//  be executed versus OrderSendReliable(), and a greater likelihood it will
//  be executed at a price worse than the entry price due to price movement.
//
//  RETURN VALUE:
//     Ticket number or -1 under some error conditions.  Check
//     final error returned by Metatrader with OrderReliableLastErr().
//     This will reset the value from GetLastError(), so in that sense it cannot
//     be a total drop-in replacement due to Metatrader flaw.
//
//  FEATURES:
//     * Most features of OrderSendReliable() but for market orders only.
//       Command must be OP_BUY or OP_SELL, and specify Bid or Ask at
//       the time of the call.
//
//     * If price moves in an unfavorable direction during the loop,
//       e.g. from requotes, then the slippage variable it uses in
//       the real attempt to the server will be decremented from the passed
//       value by that amount, down to a minimum of zero.   If the current
//       price is too far from the entry value minus slippage then it
//       will not attempt an order, and it will signal, manually,
//       an ERR_INVALID_PRICE (displayed to log as usual) and will continue
//       to loop the usual number of times.
//
//     * Displays various error messages on the log for debugging.
//
//  ORIGINAL AUTHOR AND DATE:
//	   Matt Kennel, 2006-08-16
//
//=============================================================================
int OrderSendReliableMKT(string symbol, int cmd, double volume, double price,
                         int slippage, double stoploss, double takeprofit,
                         string comment="", int magic=0, datetime expiration=0,
                         color arrow_color=CLR_NONE)
{
	string fn = __FUNCTION__ + "[]";

	int ticket = -1;
	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!orUseForTesting)
	{
		if (IsOptimization()  ||  IsTesting())
		{
			ticket = OrderSend(symbol, cmd, volume, price, slippage, stoploss,
			                   takeprofit, comment, magic, expiration, arrow_color);
			return(ticket);
		}
	}
	// ========================================================================
	
	// Cannot use this function for pending orders
	if (cmd > OP_SELL)
	{
		ticket = OrderSendReliable(symbol, cmd, volume, price, slippage, 0, 0, 
								   comment, magic, expiration, arrow_color);
		return(ticket);
	}
	
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	// Get information about this order
	int digits;
	double point;
	double bid, ask;
	double sl, tp;
	GetOrderDetails(0, symbol, cmd, digits, point, sl, tp, bid, ask, false);
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	
	OrderReliablePrint(fn, "");
	OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
	OrderReliablePrint(fn, "Attempted " + OrderTypeToString(cmd) + " " + symbol + ": " + DoubleToStr(volume, 3) + " lots @" + 
	                   DoubleToStr(price, digits+1) + " sl:" + DoubleToStr(stoploss, digits+1) + " tp:" + DoubleToStr(takeprofit, digits+1));

	price = NormalizeDouble(price, digits);
	stoploss = NormalizeDouble(stoploss, digits);
	takeprofit = NormalizeDouble(takeprofit, digits);
	EnsureValidStops(symbol, cmd, price, stoploss, takeprofit);

	int cnt;
	int err = GetLastError(); // clear the global variable.
	err = 0;
	bool exitLoop = false;

	if ((cmd == OP_BUY) || (cmd == OP_SELL))
	{
		cnt = 0;
		while (!exitLoop)
		{
			double pnow = price;
			int slippagenow = slippage;
			if (cmd == OP_BUY)
			{
				// modification by Paul Hampton-Smith to replace RefreshRates()
				pnow = NormalizeDouble(MarketInfo(symbol, MODE_ASK), MarketInfo(symbol, MODE_DIGITS)); // we are buying at Ask
				if (pnow > price)
				{
					slippagenow = slippage - (pnow - price) / point;
				}
			}
			else if (cmd == OP_SELL)
			{
				// modification by Paul Hampton-Smith to replace RefreshRates()
				pnow = NormalizeDouble(MarketInfo(symbol, MODE_BID), MarketInfo(symbol, MODE_DIGITS)); // we are buying at Ask
				if (pnow < price)
				{
					// moved in an unfavorable direction
					slippagenow = slippage - (price - pnow) / point;
				}
			}
			if (slippagenow > slippage) slippagenow = slippage;
			if (slippagenow >= 0)
			{

				ticket = OrderSend(symbol, cmd, volume, pnow, slippagenow,
				                   stoploss, takeprofit, comment, magic,
				                   expiration, arrow_color);
				err = GetLastError();
			}
			else
			{
				// too far away, manually signal ERR_INVALID_PRICE, which
				// will result in a sleep and a retry.
				err = ERR_INVALID_PRICE;
			}

			switch (err)
			{
				case ERR_NO_ERROR:
					exitLoop = true;
					break;

				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_INVALID_PRICE:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_TRADE_CONTEXT_BUSY:
				case ERR_TRADE_TIMEOUT:
				case ERR_TRADE_DISABLED:
				case ERR_MARKET_CLOSED:	// Added 16Jun20
					cnt++; // a retryable error
					break;

				case ERR_PRICE_CHANGED:
				case ERR_REQUOTE:
					// Paul Hampton-Smith removed RefreshRates() here and used MarketInfo() above instead
					continue; // we can apparently retry immediately according to MT docs.

				default:
					// an apparently serious, unretryable error.
					exitLoop = true;
					break;

			}  // end switch

			if (cnt > orRetryAttempts)
				exitLoop = true;

			if (!exitLoop)
			{
				OrderReliablePrint(fn, "Result of attempt " + IntegerToString(cnt) + " of " + orRetryAttempts + ": Retryable error: " + OrderReliableErrTxt(err));
				OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
				SleepRandomTime();
			}
			else
			{
				if (err != ERR_NO_ERROR  &&  err != ERR_NO_RESULT)
				{
					OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
				}
				if (cnt > orRetryAttempts)
				{
					OrderReliablePrint(fn, "Retry attempts maxed at " + orRetryAttempts);
				}
			}
		}

		// we have now exited from loop.
		if (err == ERR_NO_ERROR  ||  err == ERR_NO_RESULT)
		{
			OrderReliablePrint(fn, "Ticket #" + IntegerToString(ticket) + ": Successful " + OrderTypeToString(cmd) + " order placed, details follow.");
			OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES);
			OrderPrint();
			OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
			OrderReliablePrint(fn, "");
			return(ticket); // SUCCESS!
		}
		OrderReliablePrint(fn, "Failed to execute OP_BUY/OP_SELL, after " + orRetryAttempts + " retries");
		OrderReliablePrint(fn, "Failed trade: " + OrderTypeToString(cmd) + " " + DoubleToStr(volume, 2) + " lots  " + symbol +
		                   "@" + DoubleToStr(price, digits) + " tp@" + takeprofit + " sl@" + stoploss);
		OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
		OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
		OrderReliablePrint(fn, "");
		return(-1);
	}
}
*/

//=============================================================================
//							 OrderSendReliable2Step()
//
//  Some brokers don't allow the SL and TP settings as part of the initial
//  market order (Water House Capital).  Therefore, this routine will first
//  place the market order with no stop-loss and take-profit but later
//  update the order accordingly
//
//	RETURN VALUE:
//     Same as OrderSendReliable; the ticket number
//
//  NOTES:
//     Order will not be updated if an error continues during
//     OrderSendReliableMKT.  No additional information will be logged
//     since OrderSendReliableMKT would have already logged the error
//     condition
//
//  ORIGINAL AUTHOR AND DATE:
//     Jack Tomlinson, 2007-05-29
//
//=============================================================================
int OrderSendReliable2Step(string symbol, int cmd, double volume, double price,
                           int slippage, double stoploss, double takeprofit,
                           string comment="", int magic=0, datetime expiration=0,
                           color arrow_color=CLR_NONE)
{
	string fn = __FUNCTION__ + "[]";

	int ticket = -1;
	double slipped = 0;
	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!orUseForTesting)
	{
		if (IsOptimization()  ||  IsTesting())
		{
			ticket = OrderSend(symbol, cmd, volume, price, slippage, 0, 0, 
							   comment, magic, 0, arrow_color);

			if (!OrderModify(ticket, price, stoploss, takeprofit, expiration, arrow_color))
				OrderReliablePrint(fn, "Order Modify of Ticket #" + IntegerToString(ticket) + " FAILED");
			
			return(ticket);
		}
	}
	// ========================================================================
	
	OrderReliablePrint(fn, "");
	OrderReliablePrint(fn, "Doing OrderSendReliable, followed by OrderModifyReliable:");

	ticket = OrderSendReliable(symbol, cmd, volume, price, slippage,
								0, 0, comment, magic, expiration, arrow_color);

	if (stoploss != 0 || takeprofit != 0)
	{
		if (ticket >= 0)
		{
			double theOpenPrice = price;
			if (OrderSelect(ticket, SELECT_BY_TICKET))
			{
				theOpenPrice = OrderOpenPrice();
				slipped = theOpenPrice - price;
				OrderReliablePrint(fn, "Selected ticket #" + IntegerToString(ticket) + ", OrderOpenPrice() = " + theOpenPrice + ", Orig Price = " + price + ", slipped = " + slipped);
			}
			else
				OrderReliablePrint(fn, "Failed to select ticket #" + IntegerToString(ticket) + " after successful 2step placement; cannot recalculate SL & TP");
			if (slipped != 0)
			{
				OrderReliablePrint(fn, "2step order slipped by: " + DoubleToStr(slipped, Digits) + "; SL & TP modified by same amount");
				if (takeprofit != 0)	takeprofit += slipped;
				if (stoploss != 0)		stoploss += slipped;
			}
			OrderModifyReliable(ticket, theOpenPrice, stoploss, takeprofit, expiration, arrow_color);
		}
	}
	else
		OrderReliablePrint(fn, "Skipping OrderModifyReliable because no SL or TP specified.");

	return(ticket);
}


//=============================================================================
//							 OrderModifyReliable()
//
//  This is intended to be a drop-in replacement for OrderModify() which,
//  one hopes, is more resistant to various forms of errors prevalent
//  with MetaTrader.
//
//  RETURN VALUE:
//     TRUE if successful, FALSE otherwise
//
//  FEATURES:
//     * Re-trying under some error conditions, sleeping a random
//       time defined by an exponential probability distribution.
//
//     * Displays various error messages on the log for debugging.
//
//
//  ORIGINAL AUTHOR AND DATE:
//     Matt Kennel, 2006-05-28
//
//=============================================================================
bool OrderModifyReliable(int ticket, double price, double stoploss,
                         double takeprofit, datetime expiration,
                         color arrow_color=CLR_NONE)
{
	string fn = __FUNCTION__ + "[]";

	bool result = false;
	bool nonRetryableError = false;
	bool skipSleep = false;

	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!orUseForTesting)
	{
		if (IsOptimization()  ||  IsTesting())
		{
			result = OrderModify(ticket, price, stoploss,
			                     takeprofit, expiration, arrow_color);
			return(result);
		}
	}
	// ========================================================================
	
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	// Get information about this order
	string symbol = "ALLOCATE";		// This is so it has memory space allocated
	int type;
	int digits;
	double point;
	double bid, ask;
	double sl, tp;
	GetOrderDetails(ticket, symbol, type, digits, point, sl, tp, bid, ask);
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
		
	OrderReliablePrint(fn, "");
	OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
	OrderReliablePrint(fn, "Attempted modify of #" + IntegerToString(ticket) + ", " + OrderTypeToString(type) + ", price:" + DoubleToStr(price, digits) +
	                   ", sl:" + DoubleToStr(stoploss, digits) + ", tp:" + DoubleToStr(takeprofit, digits) + 
	                   ", exp:" + TimeToStr(expiration));

	// Below, we call "EnsureValidStops".  If the order we are modifying 
	// is a pending order, then we should use the price passed in.  But 
	// if it's an open order, the price passed in is irrelevant; we need 
	// to use the appropriate bid or ask, so get those...
	double prc = price;
	if (type == OP_BUY)			prc = bid;
	else if (type == OP_SELL)	prc = ask;

	// With the requisite info, we can do error checking on SL & TP
	prc = NormalizeDouble(prc, digits);
	price = NormalizeDouble(price, digits);
	stoploss = NormalizeDouble(stoploss, digits);
	takeprofit = NormalizeDouble(takeprofit, digits);
	
	// If SL/TP are not changing then send in zeroes to EnsureValidStops(),
	// so that it does not bother to try to change them
	double newSL = stoploss;
	double newTP = takeprofit;
	if (stoploss == sl)		newSL = 0;
	if (takeprofit == tp)	newTP = 0;
	EnsureValidStops(symbol, type, prc, newSL, newTP, false);
	if (stoploss != sl)		stoploss = newSL;
	if (takeprofit != tp)	takeprofit = newTP;


	int cnt = 0;
	int err = GetLastError(); // so we clear the global variable.
	err = 0;
	bool exitLoop = false;

	while (!exitLoop)
	{
		result = OrderModify(ticket, price, stoploss,
		                     takeprofit, expiration, arrow_color);
		err = GetLastError();

		if (result)
			break;	// exit while loop if modify successful

		skipSleep = false;
		
		// Exclusively for debugging
		if (err == ERR_NO_ERROR)
			OrderReliablePrint(fn, "OrderModifyReliable, ERR_NO_ERROR received, but OrderModify() still returned false; exiting");
		else if (err == ERR_INVALID_STOPS)
			OrderReliablePrint(fn, "OrderModifyReliable, ERR_INVALID_STOPS, Broker\'s Min Stop Level (in pips) = " + DoubleToStr(MarketInfo(symbol, MODE_STOPLEVEL) * Point / AdjPoint(symbol), 1));
		else if (err == ERR_TRADE_MODIFY_DENIED)
			OrderReliablePrint(fn, "OrderModifyReliable, ERR_TRADE_MODIFY_DENIED, cause unknown");
			//EnsureValidStops(symbol, price, stoploss, takeprofit);

		switch (err)
		{
			// No error or non-retryable
			case ERR_MARKET_CLOSED:
			case ERR_TRADE_DISABLED:
				nonRetryableError = true;
			case ERR_NO_ERROR:
			case ERR_NO_RESULT:				// Attempted mod to existing value; see below for reported result		
				exitLoop = true;
				break;

			// Retryable errors
			case ERR_PRICE_CHANGED:
			case ERR_REQUOTE:
				skipSleep = true;			// we can apparently retry immediately according to MT docs (so no sleep)
			case ERR_INVALID_STOPS:	
			case ERR_COMMON_ERROR:
			case ERR_SERVER_BUSY:
			case ERR_NO_CONNECTION:
			case ERR_TOO_FREQUENT_REQUESTS:
			case ERR_TRADE_TIMEOUT:			// for modify this is a retryable error, I hope.
			case ERR_INVALID_PRICE:
			case ERR_OFF_QUOTES:
			case ERR_BROKER_BUSY:
			case ERR_TOO_MANY_REQUESTS:
			case ERR_TRADE_CONTEXT_BUSY:
			case ERR_TRADE_MODIFY_DENIED:	// This one may be important; have to Ensure Valid Stops AND valid price (for pends)
				cnt++; 	// a retryable error
				break;

			default:				// an apparently serious, unretryable error.
				OrderReliablePrint(fn, "Unknown error occured: " + err);
				exitLoop = true;
				nonRetryableError = true;
				break;	
		}

		if (cnt > orRetryAttempts)
		{
			OrderReliablePrint(fn, "Retry attempts maxed at " + IntegerToString(orRetryAttempts));
			exitLoop = true;
		}
		if (exitLoop)
		{
			if (nonRetryableError)
				OrderReliablePrint(fn, "Non-retryable error: "  + OrderReliableErrTxt(err));
			break;
		}
		else
		{
			OrderReliablePrint(fn, "Result of attempt " + IntegerToString(cnt) + " of " + IntegerToString(orRetryAttempts) + ": Retryable error: " + OrderReliableErrTxt(err));
			OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
			if (!skipSleep)
				SleepRandomTime();
			RefreshRates();
		}
	}

	// we have now exited from loop.
	if (err == ERR_NO_RESULT)
	{
		OrderReliablePrint(fn, "Server reported modify order did not actually change parameters.");
		OrderReliablePrint(fn, "Redundant modification: " + IntegerToString(ticket) + " " + symbol +
		                   "@" + DoubleToStr(price, digits) + " tp@" + DoubleToStr(takeprofit, digits) + " sl@" + DoubleToStr(stoploss, digits));
		OrderReliablePrint(fn, "Suggest modifying code logic to avoid.");
	}
	
	if (result)
	{
		OrderReliablePrint(fn, "Ticket #" + IntegerToString(ticket) + ": Modification successful, updated trade details follow.");
		if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
			OrderReliablePrint(fn, "Could Not Select Ticket #" + IntegerToString(ticket));
		OrderPrint();
	}
	else
	{
		if (cnt > 0)
			OrderReliablePrint(fn, "Failed to execute modify after " + IntegerToString(cnt-1) + " retries");
		OrderReliablePrint(fn, "Failed modification: #"  + IntegerToString(ticket) + ", " + OrderTypeToString(type) + ", " + symbol +
	                   	"@" + DoubleToStr(price, digits) + " sl@" + DoubleToStr(stoploss, digits) + " tp@" + DoubleToStr(takeprofit, digits));
		OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
	}
	OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
	OrderReliablePrint(fn, "");
	return(result);
}


//=============================================================================
//                            OrderCloseReliable()
//
//  This is intended to be a drop-in replacement for OrderClose() which,
//  one hopes, is more resistant to various forms of errors prevalent
//  with MetaTrader.
//
//  RETURN VALUE:
//     TRUE if successful, FALSE otherwise
//
//  FEATURES:
//     * Re-trying under some error conditions, sleeping a random
//       time defined by an exponential probability distribution.
//
//     * Displays various error messages on the log for debugging.
//
//  ORIGINAL AUTHOR AND DATE:
//     Derk Wehler, 2006-07-19
//
//=============================================================================
bool OrderCloseReliable(int ticket, double volume, double price,
						int slippage, color arrow_color=CLR_NONE)
{
	string fn = __FUNCTION__ + "[]";

	bool result = false;
	bool nonRetryableError = false;
	bool skipSleep = false;
	
	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!orUseForTesting)
	{
		if (IsOptimization()  ||  IsTesting())
		{
			result = OrderClose(ticket, volume, price, slippage, arrow_color);
			return(result);
		}
	}
	// ========================================================================
	

	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	// Get information about this order
	string symbol = "ALLOCATE";		// This is so it has memory space allocated
	int type;
	int digits;
	double point;
	double bid, ask;
	double sl, tp;
	
	// If this fails, we're probably in trouble
	GetOrderDetails(ticket, symbol, type, digits, point, sl, tp, bid, ask);
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

	OrderReliablePrint(fn, "");
	OrderReliablePrint(fn, "º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º");
	OrderReliablePrint(fn, "Attempted close of #" + IntegerToString(ticket) + " initial price:" + DoubleToStr(price, digits) +
	                   " lots:" + DoubleToStr(volume, 3) + " slippage:" + IntegerToString(slippage));


	if (type != OP_BUY  &&  type != OP_SELL)
	{
		OrderReliablePrint(fn, "Error: Trying to close ticket #" + IntegerToString(ticket) + ", which is " + OrderTypeToString(type) + ", not OP_BUY or OP_SELL");
		return(false);
	}


	int cnt = 0;
	int err = GetLastError(); // so we clear the global variable.
	err = 0;
	bool exitLoop = false;
	double priceNow = 0;
	double hasSlippedBy = 0;

	while (!exitLoop)
	{
		skipSleep = false;

		// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =
		// Get current price and calculate slippage
		if (point != 0)
		{
			if (type == OP_BUY)
			{
				priceNow = NormalizeDouble(MarketInfo(symbol, MODE_BID), digits);	// Close @ Bid
				hasSlippedBy = (price - priceNow) / point;	// (Adjusted Point)
			}
			else // if (type == OP_SELL)
			{
				priceNow = NormalizeDouble(MarketInfo(symbol, MODE_ASK), digits);	// Close @ Ask
				hasSlippedBy = (priceNow - price) / point;	// (Adjusted Point)
			}
		}
		
		// Check if slippage is more than caller's maximum allowed
		if (priceNow != price  &&  hasSlippedBy > slippage)
		{
			// Actual price has slipped against us more than user allowed
			// Log error message, sleep, and try again
			OrderReliablePrint(fn, "Actual Price (Bid for buy, Ask for sell) Value = " + DoubleToStr(priceNow, Digits) + "; Slippage from Requested Price = " + DoubleToStr(hasSlippedBy, 1) + " pips.  Retrying...");
			result = false;
			err = ERR_PRICE_CHANGED;
		}
		else
		{
			result = OrderClose(ticket, volume, priceNow, (int)(slippage - hasSlippedBy), arrow_color);
			err = GetLastError();
		}
		// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =

		if (result)
			break;	// exit while loop if close successful

		// Exclusively for debugging
		if (err == ERR_NO_ERROR)
			OrderReliablePrint(fn, "OrderCloseReliable, ERR_NO_ERROR received, but OrderClose() still returned false; exiting");
		else if (err == ERR_NO_RESULT)
			OrderReliablePrint(fn, "OrderCloseReliable, ERR_NO_RESULT received, but OrderClose() returned false; exiting");
		else if (err == ERR_INVALID_PRICE)
			OrderReliablePrint(fn, "OrderModifyReliable, ERR_INVALID_PRICE, Broker\'s Min Stop Level (in pips) = " + DoubleToStr(MarketInfo(symbol, MODE_STOPLEVEL) * Point / AdjPoint(symbol), 1));
		else if (err == ERR_TRADE_MODIFY_DENIED)
			OrderReliablePrint(fn, "OrderModifyReliable, ERR_TRADE_MODIFY_DENIED, cause unknown");
			//EnsureValidStops(symbol, price, stoploss, takeprofit);
	
		switch (err)
		{
			// No error or non-retryable
			case ERR_MARKET_CLOSED:
			case ERR_TRADE_DISABLED:
				nonRetryableError = true;
			case ERR_NO_ERROR:
			case ERR_NO_RESULT:				// Attempted mod to existing value; see below for reported result		
				exitLoop = true;
				break;
	
			// Retryable error
			case ERR_PRICE_CHANGED:
			case ERR_REQUOTE:
				skipSleep = true;			// we can apparently retry immediately according to MT docs (so no sleep)
			case ERR_INVALID_PRICE:
			case ERR_COMMON_ERROR:
			case ERR_SERVER_BUSY:
			case ERR_NO_CONNECTION:
			case ERR_TOO_FREQUENT_REQUESTS:
			case ERR_TRADE_TIMEOUT:			// for close this is a retryable error, I hope.
			case ERR_OFF_QUOTES:
			case ERR_BROKER_BUSY:
			case ERR_TOO_MANY_REQUESTS:	
			case ERR_TRADE_CONTEXT_BUSY:
				cnt++;
				break;
	
			default:						// Any other error is an apparently serious, unretryable error.
				OrderReliablePrint(fn, "Unknown error occured: " + err);
				exitLoop = true;
				nonRetryableError = true;
				break;
		}

		if (cnt > orRetryAttempts)
		{
			OrderReliablePrint(fn, "Retry attempts maxed at " + IntegerToString(orRetryAttempts));
			exitLoop = true;
		}
		if (exitLoop)
		{
			if (nonRetryableError)
				OrderReliablePrint(fn, "Non-retryable error: "  + OrderReliableErrTxt(err));
			break;
		}
		else
		{
			OrderReliablePrint(fn, "Result of attempt " + IntegerToString(cnt) + " of " + IntegerToString(orRetryAttempts) + ": Retryable error: " + OrderReliableErrTxt(err));
			OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
			if (!skipSleep)
				SleepRandomTime();
			RefreshRates();
		}
	}

	// We have now exited from loop
	if (result  ||  err == ERR_NO_RESULT  ||  err == ERR_NO_ERROR)
	{
		if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
			OrderReliablePrint(fn, "Successful close of Ticket #" + IntegerToString(ticket) + "     [ Last error: " + OrderReliableErrTxt(err) + " ]");
		else if (OrderCloseTime() > 0)	// Then it closed ok
			OrderReliablePrint(fn, "Successful close of Ticket #" + IntegerToString(ticket) + "     [ Last error: " + OrderReliableErrTxt(err) + " ]");
		else
		{
			OrderReliablePrint(fn, "Close result reported success (or failure, but w/ERR_NO_ERROR); yet order remains!  Must re-try close from EA logic!");
			OrderReliablePrint(fn, "Close Failed: Ticket #" + IntegerToString(ticket) + ", Price: " +
		                   		DoubleToStr(price, digits) + ", Slippage: " + IntegerToString(slippage));
			OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
			result = false;
		}
	}
	else
	{
		if (cnt > 0)
			OrderReliablePrint(fn, "Failed to execute close after " + IntegerToString(cnt-1) + " retries");
		OrderReliablePrint(fn, "Failed close on " + symbol + ": Ticket #" + IntegerToString(ticket) + " @ Price: " + DoubleToStr(priceNow, digits) + 
	                   	   " (Requested Price: " + DoubleToStr(price, digits) + "), Slippage: " + IntegerToString(slippage));
		OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
	}
	OrderReliablePrint(fn, "º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º");
	OrderReliablePrint(fn, "");
	return(result);
}


//=============================================================================
//                           OrderCloseReliableMKT()
//
//	This function is intended for closing orders ASAP; the principal 
//  difference is that in its internal retry-loop, it uses the new "Bid" 
//  and "Ask" real-time variables as opposed to the OrderCloseReliable(), 
//  which uses only the price given upon entry to the routine.  More likely 
//  to get the order closed if price moves, but more likely to "slip"
//
//  RETURN VALUE:
//     TRUE if successful, FALSE otherwise
//
//  FEATURES:
//     * Re-trying under some error conditions, sleeping a random
//       time defined by an exponential probability distribution.
//
//     * Displays various error messages on the log for debugging.
//
//  ORIGINAL AUTHOR AND DATE:
//     Derk Wehler, 2009-04-03
//
//=============================================================================
bool OrderCloseReliableMKT(int ticket, double volume, double price,
						   int slippage, color arrow_color=CLR_NONE)
{
	string fn = __FUNCTION__ + "[]";

	bool result = false;
	bool nonRetryableError = false;
	bool skipSleep = false;
	
	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!orUseForTesting)
	{
		if (IsOptimization()  ||  IsTesting())
		{
			result = OrderClose(ticket, volume, price, slippage, arrow_color);
			return(result);
		}
	}
	// ========================================================================
	

	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	// Get information about this order
	string symbol = "ALLOCATE";		// This is so it has memory space allocated
	int type;
	int digits;
	double point;
	double bid, ask;
	double sl, tp;
	GetOrderDetails(ticket, symbol, type, digits, point, sl, tp, bid, ask);
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

	OrderReliablePrint(fn, "");
	OrderReliablePrint(fn, "º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º");
	OrderReliablePrint(fn, "Attempted close of #" + IntegerToString(ticket) + " initial price:" + DoubleToStr(price, digits) +
	                   " lots:" + DoubleToStr(price, 3) + " slippage:" + IntegerToString(slippage));


	if (type != OP_BUY  &&  type != OP_SELL)
	{
		OrderReliablePrint(fn, "Error: Trying to close ticket #" + IntegerToString(ticket) + ", which is " + OrderTypeToString(type) + ", not OP_BUY or OP_SELL");
		return(false);
	}


	int cnt = 0;
	int err = GetLastError(); // so we clear the global variable.
	err = 0;
	bool exitLoop = false;
	double pnow = 0;
	int slippagenow = slippage;

	while (!exitLoop)
	{
		skipSleep = false;
		
		if (point != 0)
		{
			if (type == OP_BUY)
			{
				pnow = NormalizeDouble(MarketInfo(symbol, MODE_ASK), digits); // we are buying at Ask
				if (pnow > price)
				{
					// Do not allow slippage to go negative; will cause error
					slippagenow = (int)(MathMax(0, slippage - (pnow - price) / point));
				}
			}
			else if (type == OP_SELL)
			{
				pnow = NormalizeDouble(MarketInfo(symbol, MODE_BID), digits); // we are buying at Ask
				if (pnow < price)
				{
					// Do not allow slippage to go negative; will cause error
					slippagenow = (int)(MathMax(0, slippage - (price - pnow) / point));
				}
			}
		}
		
		result = OrderClose(ticket, volume, pnow, slippagenow, arrow_color);
		err = GetLastError();

		if (result)
			break;	// exit while loop if close successful

		// Exclusively for debugging
		if (err == ERR_NO_ERROR)
			OrderReliablePrint(fn, "OrderCloseReliable, ERR_NO_ERROR received, but OrderClose() still returned false; exiting");
		else if (err == ERR_NO_RESULT)
			OrderReliablePrint(fn, "OrderCloseReliable, ERR_NO_RESULT received, but OrderClose() returned false; exiting");
		else if (err == ERR_INVALID_PRICE)
			OrderReliablePrint(fn, "OrderModifyReliable, ERR_INVALID_PRICE, Broker\'s Min Stop Level (in pips) = " + DoubleToStr(MarketInfo(symbol, MODE_STOPLEVEL) * Point / AdjPoint(symbol), 1));
		else if (err == ERR_TRADE_MODIFY_DENIED)
			OrderReliablePrint(fn, "OrderModifyReliable, ERR_TRADE_MODIFY_DENIED, cause unknown");
			//EnsureValidStops(symbol, price, stoploss, takeprofit);
	
		switch (err)
		{
			// No error or non-retryable
			case ERR_MARKET_CLOSED:
			case ERR_TRADE_DISABLED:
				nonRetryableError = true;
			case ERR_NO_ERROR:
			case ERR_NO_RESULT:				// Attempted mod to existing value; see below for reported result		
				exitLoop = true;
				break;
	
			// Retryable error
			case ERR_PRICE_CHANGED:
			case ERR_REQUOTE:
				skipSleep = true;			// we can apparently retry immediately according to MT docs (so no sleep)
			case ERR_INVALID_PRICE:
			case ERR_COMMON_ERROR:
			case ERR_SERVER_BUSY:
			case ERR_NO_CONNECTION:
			case ERR_TOO_FREQUENT_REQUESTS:
			case ERR_TRADE_TIMEOUT:			// for close this is a retryable error, I hope.
			case ERR_OFF_QUOTES:
			case ERR_BROKER_BUSY:
			case ERR_TOO_MANY_REQUESTS:	
			case ERR_TRADE_CONTEXT_BUSY:
				cnt++;
				break;
	
			default:						// Any other error is an apparently serious, unretryable error.
				OrderReliablePrint(fn, "Unknown error occured: " + err);
				exitLoop = true;
				nonRetryableError = true;
				break;
		}

		if (cnt > orRetryAttempts)
		{
			OrderReliablePrint(fn, "Retry attempts maxed at " + IntegerToString(orRetryAttempts));
			exitLoop = true;
		}
		if (exitLoop)
		{
			if (nonRetryableError)
				OrderReliablePrint(fn, "Non-retryable error: "  + OrderReliableErrTxt(err));
			break;
		}
		else
		{
			OrderReliablePrint(fn, "Result of attempt " + IntegerToString(cnt) + " of " + IntegerToString(orRetryAttempts) + ": Retryable error: " + OrderReliableErrTxt(err));
			OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
			if (!skipSleep)
				SleepRandomTime();
			RefreshRates();
		}
	}

	// we have now exited from loop.
	if (result)
	{
		if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
			OrderReliablePrint(fn, "Successful close of Ticket #" + IntegerToString(ticket) + "     [ Last error: " + OrderReliableErrTxt(err) + " ]");
		else if (OrderCloseTime() > 0)	// Then it closed ok
			OrderReliablePrint(fn, "Successful close of Ticket #" + IntegerToString(ticket) + "     [ Last error: " + OrderReliableErrTxt(err) + " ]");
		else
		{
			OrderReliablePrint(fn, "Close result reported success, but order remains!  Must re-try close from EA logic!");
			OrderReliablePrint(fn, "Close Failed: Ticket #" + IntegerToString(ticket) + ", Price: " +
		                   		DoubleToStr(price, digits) + ", Slippage: " + IntegerToString(slippage));
			OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
			result = false;
		}
	}
	else
	{
		if (cnt > 0)
			OrderReliablePrint(fn, "Failed to execute close after " + IntegerToString(orRetryAttempts) + " retries");
		OrderReliablePrint(fn, "Failed close on " + symbol + ": Ticket #" + IntegerToString(ticket) + " @ Price: " +
	                   		DoubleToStr(pnow, digits) + " (Initial Price: " + DoubleToStr(price, digits) + "), Slippage: " + 
	                   		IntegerToString(slippagenow) + " (Initial Slippage: " + IntegerToString(slippage) + ")");
		OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
	}
	OrderReliablePrint(fn, "º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º");
	OrderReliablePrint(fn, "");
	return(result);
}


//=============================================================================
//                            OrderDeleteReliable()
//
//  This is intended to be a drop-in replacement for OrderDelete() which,
//  one hopes, is more resistant to various forms of errors prevalent
//  with MetaTrader.
//
//  RETURN VALUE:
//     TRUE if successful, FALSE otherwise
//
//
//  FEATURES:
//     * Re-trying under some error conditions, sleeping a random
//       time defined by an exponential probability distribution.
//
//     * Displays various error messages on the log for debugging.
//
//  ORIGINAL AUTHOR AND DATE:
//     Derk Wehler, 2006-12-21
//
//=============================================================================
bool OrderDeleteReliable(int ticket, color clr=CLR_NONE)
{
	string fn = __FUNCTION__ + "[]";

	bool result = false;
	bool nonRetryableError = false;

	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!orUseForTesting)
	{
		if (IsOptimization()  ||  IsTesting())
		{
			result = OrderDelete(ticket, clr);
			return(result);
		}
	}
	// ========================================================================
	
	OrderReliablePrint(fn, "");
	OrderReliablePrint(fn, "º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º");
	OrderReliablePrint(fn, "Attempted deletion of pending order, #" + IntegerToString(ticket));
	

	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	// Get information about this order
	string symbol = "ALLOCATE";		// This is so it has memory space allocated
	int type;
	int digits;
	double point;
	double bid, ask;
	double sl, tp;
	GetOrderDetails(ticket, symbol, type, digits, point, sl, tp, bid, ask);
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
		
	if (type == OP_BUY || type == OP_SELL)
	{
		OrderReliablePrint(fn, "error: Trying to close ticket #" + IntegerToString(ticket) +
		                   ", which is " + OrderTypeToString(type) +
		                   ", not OP_BUYSTOP, OP_SELLSTOP, OP_BUYLIMIT, or OP_SELLLIMIT");
		return(false);
	}


	int cnt = 0;
	int err = GetLastError(); // so we clear the global variable.
	err = 0;
	bool exitLoop = false;

	while (!exitLoop)
	{
		result = OrderDelete(ticket, clr);
		err = GetLastError();

		if (result == true)
			exitLoop = true;
		else
		{
			switch (err)
			{
				case ERR_NO_ERROR:
					exitLoop = true;
					OrderReliablePrint(fn, "ERR_NO_ERROR received, but OrderDelete() still returned false; exiting");
					break;

				case ERR_NO_RESULT:
					exitLoop = true;
					OrderReliablePrint(fn, "ERR_NO_RESULT received, but OrderDelete() returned false; exiting");
					break;

				case ERR_COMMON_ERROR:
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_TOO_FREQUENT_REQUESTS:
				case ERR_TRADE_TIMEOUT:		// for delete this is a retryable error, I hope.
				case ERR_TRADE_DISABLED:
				case ERR_OFF_QUOTES:
				case ERR_PRICE_CHANGED:
				case ERR_BROKER_BUSY:
				case ERR_REQUOTE:
				case ERR_TOO_MANY_REQUESTS:
				case ERR_TRADE_CONTEXT_BUSY:
				case ERR_MARKET_CLOSED:	// Added 16Jun20
					cnt++; 	// a retryable error
					break;

				default:	// Any other error is an apparently serious, unretryable error.
					exitLoop = true;
					nonRetryableError = true;
					break;

			}  // end switch
		}

		if (cnt > orRetryAttempts)
			exitLoop = true;

		if (!exitLoop)
		{
			OrderReliablePrint(fn, "Result of attempt " + IntegerToString(cnt) + " of " + IntegerToString(orRetryAttempts) + ": Retryable error: " + OrderReliableErrTxt(err));
			OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
			SleepRandomTime();
		}
		else
		{
			if (cnt > orRetryAttempts)
				OrderReliablePrint(fn, "Retry attempts maxed at " + IntegerToString(orRetryAttempts));
			else if (nonRetryableError)
				OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
		}
	}

	// we have now exited from loop.
	if (result)
	{
		OrderReliablePrint(fn, "Successful deletion of Ticket #" + IntegerToString(ticket));
		OrderReliablePrint(fn, "º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º");
		return(true); // SUCCESS!
	}
	else
	{
		OrderReliablePrint(fn, "Failed to execute delete after " + IntegerToString(orRetryAttempts) + " retries");
		OrderReliablePrint(fn, "Failed deletion: Ticket #" + IntegerToString(ticket));
		OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
	}
	OrderReliablePrint(fn, "º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º");
	OrderReliablePrint(fn, "");
	return(result);
}



//=============================================================================
//=============================================================================
//								Utility Functions
//=============================================================================
//=============================================================================

string OrderReliableErrTxt(int err)
{
	return (IntegerToString(err) + "  ::  " + ErrorDescription(err));
}


// Defaut level is 3
// Use level = 1 to Print all but "Retry" messages
// Use level = 0 to Print nothing
void OrderReliableSetErrorLevel(int level)
{
	orErrorLevel = level;
}


void OrderReliablePrint(string f, string s)
{
	// Print to log prepended with stuff;
	if (orErrorLevel >= 99 || (!(IsTesting() || IsOptimization())))
	{
		if (orErrorLevel > 0)
			Print(f + " " + OrderReliableVersion + ":     " + s);
	}
}


string OrderTypeToString(int type)
{
	if (type == OP_BUY) 		return("BUY");
	if (type == OP_SELL) 		return("SELL");
	if (type == OP_BUYSTOP) 	return("BUY STOP");
	if (type == OP_SELLSTOP)	return("SELL STOP");
	if (type == OP_BUYLIMIT) 	return("BUY LIMIT");
	if (type == OP_SELLLIMIT)	return("SELL LIMIT");
	return("None (" + IntegerToString(type) + ")");
}


//=============================================================================
//                        EnsureValidStops()
//
//  Most MQ4 brokers have a minimum stop distance, which is the number of 
//  pips from price where a pending order can be placed or where a SL & TP 
//  can be placed.  THe purpose of this function is to detect when the 
//  requested SL or TP is too close, and to move it out automatically, so 
//  that we do not get ERR_INVALID_STOPS errors.
//
//  FUNCTION COMPLETELY OVERHAULED:
//     Derk Wehler, 2008-11-08
//
//=============================================================================
void EnsureValidStops(string symbol, int cmd, double price, double& sl, double& tp, bool isNewOrder=true)
{
	string fn = __FUNCTION__ + "[]";
	
	double point = MarketInfo(symbol, MODE_POINT);
	
	// We only use point for StopLevel, and StopLevel is reported as 10 times
	// what you expect on a 5-digit broker, so leave it as is.
	//if (point == 0.001  ||  point == 0.00001)
	//	point *= 10;
	
	int digits = (int)MarketInfo(symbol, MODE_DIGITS);
	double 	orig_sl = sl;
	double 	orig_tp = tp;
	double 	new_sl, new_tp;
	double	min_stop_level = MarketInfo(symbol, MODE_STOPLEVEL);
	double 	servers_min_stop = min_stop_level * point;
	double 	spread = MarketInfo(symbol, MODE_ASK) - MarketInfo(symbol, MODE_BID);
	//Print("        EnsureValidStops: Symbol = " + symbol + ",  servers_min_stop = " + servers_min_stop); 

	// Skip if no S/L (zero)
	if (sl != 0)
	{
		if (cmd % 2 == 0)	// we are long
		{
			// for pending orders, sl/tp can bracket price by servers_min_stop
			new_sl = price - servers_min_stop;
			//Print("        EnsureValidStops: new_sl [", new_sl, "] = price [", price, "] - servers_min_stop [", servers_min_stop, "]"); 
			
			// for market order, sl/tp must bracket bid/ask
			if (cmd == OP_BUY  &&  isNewOrder)
			{
				new_sl -= spread;	
				//Print("        EnsureValidStops: Minus spread [", spread, "]"); 
			}
			sl = MathMin(sl, new_sl);
		}
		else	// we are short
		{
			new_sl = price + servers_min_stop;	// we are short
			//Print("        EnsureValidStops: new_sl [", new_sl, "] = price [", price, "] + servers_min_stop [", servers_min_stop, "]"); 
			
			// for market order, sl/tp must bracket bid/ask
			if (cmd == OP_SELL  &&  isNewOrder)
			{
				new_sl += spread;	
				//Print("        EnsureValidStops: Plus spread [", spread, "]"); 
			}

			sl = MathMax(sl, new_sl);
		}
		sl = NormalizeDouble(sl, digits);
	}


	// Skip if no T/P (zero)
	if (tp != 0)
	{
		// check if we have to adjust the stop
		if (MathAbs(price - tp) <= servers_min_stop)
		{
			if (cmd % 2 == 0)	// we are long
			{
				new_tp = price + servers_min_stop;	// we are long
				tp = MathMax(tp, new_tp);
			}
			else	// we are short
			{
				new_tp = price - servers_min_stop;	// we are short
				tp = MathMin(tp, new_tp);
			}
			tp = NormalizeDouble(tp, digits);
		}
	}
	
	// notify if changed
	if (sl != orig_sl)
		OrderReliablePrint(fn, "SL was too close to brokers min distance (" + DoubleToStr(min_stop_level, 1) + "); moved SL to: " + DoubleToStr(sl, digits));
	if (tp != orig_tp)
		OrderReliablePrint(fn, "TP was too close to brokers min distance (" + DoubleToStr(min_stop_level, 1) + "); moved TP to: " + DoubleToStr(tp, digits));
}


//=============================================================================
//                            EnsureValidPendPrice()
//
//  This function is called if OrderSendReliable gets an ERR_INVALID_PRICE 
//  or ERR_INVALID_STOPS error when attempting to place a pending order. 
//  We assume these are signs that the brokers minumum stop distance, which 
//  is what is used for pending distances as well, is too small and the price 
//  is too close to the pending's requested price.  Therefore we want to do 
//  one of two things: 
//
//  If orUseLimitToMarket is enabled, then see if the actual and requested 
//  prices are close enough to be within the requested slippage, and if so 
//  return true to indicate a swap to a market order.
//
//  Otherwise, we move the requested price far enough from current price to 
//  (hopefully) place the pending order, and return false (price, sl & tp  
//  are all I/O params).  If this does not work, and the the same error is 
//  received, and the function is called again, it attempts to move the 
//  entry price (and sl & tp) out one more pip at a time.
//
//  RETURN VALUE:
//     True if calling function should convert this to market order, 
//     otherwise False
//
//  ORIGINAL AUTHOR AND DATE:
//     Derk Wehler, 2011-05-17
//
//=============================================================================
bool EnsureValidPendPrice(int err, bool& fixed, string symbol, int cmd, double& price, 
						  double& stoploss, double& takeprofit, int slippage, double point, int digits)
{
	string fn = __FUNCTION__ + "[]";

	double 	servers_min_stop = MarketInfo(symbol, MODE_STOPLEVEL) * Point;
	double 	old_price, hasSlippedBy = 0;
	double 	priceNow = 0;
	
	// Assume buy pendings relate to Ask, and sell pendings relate to Bid
	if (cmd % 2 == OP_BUY)
		priceNow = NormalizeDouble(MarketInfo(symbol, MODE_ASK), digits);
	else if (cmd % 2 == OP_SELL)
		priceNow = NormalizeDouble(MarketInfo(symbol, MODE_BID), digits);

	// If we are too close to put in a limit/stop order so go to market.
	if (MathAbs(priceNow - price) <= servers_min_stop)
	{
		if (orUseLimitToMarket)
		{
			if (point != 0)
				hasSlippedBy = MathAbs(priceNow - price) / point;	// (Adjusted Point)

			// Check if slippage is more than caller's maximum allowed
			if (priceNow != price  &&  hasSlippedBy > slippage)
			{
				// Actual price is too far from requested price to do market order, 
				// and too close to place pending order (because of broker's minimum 
				// stop distance).  Therefore, report the problem and try again...
				OrderReliablePrint(fn, "Actual price (Ask for buy, Bid for sell) = " + DoubleToStr(priceNow, Digits) + ", and requested pend price = " + DoubleToStr(priceNow, Digits) + "; slippage between the two = ±" + DoubleToStr(hasSlippedBy, 1) + " pips, which is larger than user specified.  Cannot Convert to Market Order.");
			}
			else
			{
				// Price has moved close enough (within slippage) to requested 
				// pending price that we can go ahead and enter a market position
				return(true);
			}
		}
		else 
		{
			if (fixed)
			{
				if (cmd == OP_BUYSTOP  ||  cmd == OP_SELLLIMIT)
				{
					price += point;
					if (stoploss > 0)   stoploss += point;
					if (takeprofit > 0) takeprofit += point;
					OrderReliablePrint(fn, "Pending " + OrderTypeToString(cmd) + " Order still has \'" + ErrorDescription(err) + "\', adding 1 pip; new price = " + DoubleToStr(price, Digits));
					if (stoploss > 0  ||  takeprofit > 0)
						OrderReliablePrint(fn, "NOTE: SL (now " + DoubleToStr(stoploss, digits) + ") & TP (now " + DoubleToStr(takeprofit, digits) + ") were adjusted proportionately");
				}
				else if (cmd == OP_BUYLIMIT  ||  cmd == OP_SELLSTOP)
				{
					price -= point;
					if (stoploss > 0)   stoploss -= point;
					if (takeprofit > 0) takeprofit -= point;
					OrderReliablePrint(fn, "Pending " + OrderTypeToString(cmd) + " Order still has \'" + ErrorDescription(err) + "\', subtracting 1 pip; new price = " + DoubleToStr(price, digits));
					if (stoploss > 0  ||  takeprofit > 0)
						OrderReliablePrint(fn, "NOTE: SL (now " + DoubleToStr(stoploss, digits) + ") & TP (now " + DoubleToStr(takeprofit, digits) + ") were adjusted proportionately");
				}
			}
			else
			{
				if (cmd == OP_BUYLIMIT)
				{
					old_price = price;
					price = priceNow - servers_min_stop;
					if (stoploss > 0)   stoploss += (price - old_price);
					if (takeprofit > 0) takeprofit += (price - old_price);
					OrderReliablePrint(fn, "Pending " + OrderTypeToString(cmd) + " has \'" + ErrorDescription(err) + "\'; new price = " + DoubleToStr(price, digits));
					if (stoploss > 0  ||  takeprofit > 0)
						OrderReliablePrint(fn, "NOTE: SL (now " + DoubleToStr(stoploss, digits) + ") & TP (now " + DoubleToStr(takeprofit, digits) + ") were adjusted proportionately");
				}
				else if (cmd == OP_BUYSTOP)
				{
					old_price = price;
					price = priceNow + servers_min_stop;
					if (stoploss > 0)   stoploss += (price - old_price);
					if (takeprofit > 0) takeprofit += (price - old_price);
					OrderReliablePrint(fn, "Pending " + OrderTypeToString(cmd) + " has \'" + ErrorDescription(err) + "\'; new price = " + DoubleToStr(price, digits));
					if (stoploss > 0  ||  takeprofit > 0)
						OrderReliablePrint(fn, "NOTE: SL (now " + DoubleToStr(stoploss, digits) + ") & TP (now " + DoubleToStr(takeprofit, digits) + ") were adjusted proportionately");
				}
				else if (cmd == OP_SELLSTOP)
				{
					old_price = price;
					price = priceNow - servers_min_stop;
					if (stoploss > 0)   stoploss -= (old_price - price);
					if (takeprofit > 0) takeprofit -= (old_price - price);
					OrderReliablePrint(fn, "Pending SellStop has \'" + ErrorDescription(err) + "\'; new price = " + DoubleToStr(price, digits));
					if (stoploss > 0  ||  takeprofit > 0)
						OrderReliablePrint(fn, "NOTE: SL (now " + DoubleToStr(stoploss, digits) + ") & TP (now " + DoubleToStr(takeprofit, digits) + ") were adjusted proportionately");
				}
				else if (cmd == OP_SELLLIMIT)
				{
					old_price = price;
					price = priceNow + servers_min_stop;
					if (stoploss > 0)   stoploss -= (old_price - price);
					if (takeprofit > 0) takeprofit -= (old_price - price);
					OrderReliablePrint(fn, "Pending SellLimit has \'" + ErrorDescription(err) + "\'; new price = " + DoubleToStr(price, digits));
					if (stoploss > 0  ||  takeprofit > 0)
						OrderReliablePrint(fn, "NOTE: SL (now " + DoubleToStr(stoploss, digits) + ") & TP (now " + DoubleToStr(takeprofit, digits) + ") were adjusted proportionately");
				}
				fixed = true;
			}
			EnsureValidStops(symbol, cmd, price, stoploss, takeprofit);
		}
	}
	return(false);
}


//=============================================================================
//                              SleepRandomTime()
//
//  This sleeps a random amount of time defined by an exponential
//  probability distribution. The mean time, in Seconds is given
//  in 'mean_time'.
//
//  This is the back-off strategy used by Ethernet.  This will
//  quantize in fiftieths of seconds, so don't call this with a too
//  small a number.  This returns immediately if we are backtesting
//  and does not sleep.
//
//=============================================================================
void SleepRandomTime()
{
	// No need for pauses on tester
	if (IsTesting())
		return;

	// 19Jun16 : Noticed for a long time that when an order fails, 
	// it fails all 10 tries.  So try a different tack here and just 
	// sleep a set time per try.
	//Sleep(200);
	//return;

	// 5Aug19 : Noticed that 200 ms didn't help anything either. 
	// Don't know what else to try; putting back random sleep time.
	double rndm = MathRand() / 32768; // = 0.0 to 0.99999
	
	// Sleep from 20-to-(2*orSleepAveTime) ms
	int ms = (int)MathRound(2 * orSleepAveTime * rndm);
	ms = MathMax(ms, 20);

	Sleep(ms);
}


//=============================================================================
//  Adjusted Point funtion
//=============================================================================
double AdjPoint(string sym="")
{
	if (sym == "")
		sym = Symbol();
	double ticksize = MarketInfo(sym, MODE_TICKSIZE);
	if (ticksize == 0.00001  ||  ticksize == 0.001)
		ticksize *= 10;
	return(ticksize);
}


//=============================================================================
//                                LimitToMarket()
//
//  Setting to toggle what OrderSendReliable does with Stop or Limit orders
//  that are requested to be placed too close to the current price.  
//
//  When set True, it will turn any such conundrum from a stop/limit order 
//  into a simple market order
//
//  When set False, the library will alter the price of the Stop/Limit order\
//  just far enough to be able to place the order as a pending order.
//
//=============================================================================
void LimitToMarket(bool limit2market)
{
	orUseLimitToMarket = limit2market;
}


//=============================================================================
//                        OrderReliableUseForTesting()
//
//  Setting to toggle whether this OrderReliable library is used in testing 
//  and optimization.  By default, it is set to false, and will thus just pass 
//  orders straight through.
//
//  When set true, it will use the full functions as normally all the time,
//  including testing / optimization.
//
//=============================================================================
void OrderReliableUseForTesting(bool use)
{
	orUseForTesting = use;
}


//=============================================================================
//                      OrderReliableAddSpreadToComment()
//
//  Setting to toggle whether this to add the current spread to the trade 
//  commment, so that user can monitor variable spread situations on a 
//  per trade basis.
//
//=============================================================================
void OrderReliableAddSpreadToComment(bool use)
{
	orAddSpreadToComment = use;
}


//=============================================================================
//                              GetOrderDetails()
//
//  For some OrderReliable functions (such as Modify), we need to know some
//  things about the order (such as direction and symbol).  To do this, we 
//  need to select the order.  However, the caller may already have an order 
//  selected so we need to be responsible and put it back when done.
//
//  Return false if there is a problem, true otherwise.
//
//=============================================================================
bool GetOrderDetails(int ticket, string& symb, int& type, int& digits, 
					 double& point, double& sl, double& tp, double& bid, 
					 double& ask, bool exists=true)
{
	string fn = __FUNCTION__ + "[]";

	bool retVal = true;
	
	// If this is existing order, select it and get symbol and type
	if (exists)
	{
		int lastTicket = OrderTicket();
		if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
		{
			OrderReliablePrint(fn, "OrderSelect() error: " + ErrorDescription(GetLastError()));
			return(false);
		}
		symb = OrderSymbol();
		type = OrderType();
		tp = OrderTakeProfit();
		sl = OrderStopLoss();
		
		// Select back the prior ticket num in case caller was using it.
		if (lastTicket >= 0)
		{
			if (!OrderSelect(lastTicket, SELECT_BY_TICKET, MODE_TRADES))
				OrderReliablePrint(fn, "Could Not Select Ticket #" + IntegerToString(lastTicket));
		}
	}
	
	// Get bid, ask, point & digits
	digits = (int)MarketInfo(symb, MODE_DIGITS);
	bid = NormalizeDouble(MarketInfo(symb, MODE_BID), digits);
	ask = NormalizeDouble(MarketInfo(symb, MODE_ASK), digits);
	point = MarketInfo(symb, MODE_POINT);
	if (point == 0.001  ||  point == 0.00001)
		point *= 10;
		
	// If this is a forex pair (i.e. symbol length == 6), then digits should not be zero
	if (StringLen(MySymbolVal2String(MySymbolConst2Val(symb))) == 6)
	{
		if (digits == 0)
		{
			// Probably not good.  Some instruments CAN have zero digits (like BTCUSD -also 6 letters) 
			// but first thing to try is see if we get a non-zero for first 6 letters.
			digits = (int)MarketInfo(StringSubstr(symb, 0, 6), MODE_DIGITS);
			if (digits == 0)
				OrderReliablePrint(fn, "error(?): MarketInfo(symbol(" + symb + "), MODE_DIGITS) == 0");
		}
		if (point == 0)
		{
			// DEFINITELY not good.  Point could be 1 or 10 or 0.1, but NOT zero; this will cause 
			// divide-by-zero errors. First thing to try is see if we get a non-zero for first 6 letters.
			point = (int)MarketInfo(StringSubstr(symb, 0, 6), MODE_POINT);
			if (point != 0)
			{
				if (point == 0.001  ||  point == 0.00001)
					point *= 10;
			}
			else
			{
				OrderReliablePrint(fn, "ERROR!!: MarketInfo(symbol(" + symb + "), MODE_POINT) == 0");
				OrderReliablePrint(fn, "ANY OPERATION DIVIDING BY POINT IS THUS DISABLED (Slippage calculation)");
				OrderReliablePrint(fn, "WILL CONTINUE TO ATTEMPT OPERATION, BUT NO PROMISES");
			}
		}
	}
	if (exists)
	{
		tp = NormalizeDouble(tp, digits);
		sl = NormalizeDouble(sl, digits);
		bid = NormalizeDouble(bid, digits);
		ask = NormalizeDouble(ask, digits);
	}
	
	return(retVal);
}

//=============================================================================
//  11Sep20:
//  This has had an illustrious history.  First I only had main 28 plud gold 
//  and silver, which if course had problems with other symbols.  Then in 
//  Feb/Mar, 2020 changed it entirely to iterate through the market watch and 
//  return the index.  This works great EXCEPT that one can change the order 
//  of the market watch and now you get a diff index for the symbol from day 
//  to day.
//
//  Therefore I decided to make a hybrid, where first, it tries to use the old 
//  way, so it will try to match symbols first, and if it cannot, it will use 
//  Market Watch index.  However this presents a problem: See below in 
//  SymbolVal2String() header.
//=============================================================================
int MySymbolConst2Val(string symbol="") 
{
	if (symbol == "")	symbol = Symbol();
	
	string mySymbol = symbol;
	StringToUpper(mySymbol);
	if (StringFind(mySymbol, "AUDCAD") != -1)	return(1);
	if (StringFind(mySymbol, "AUDCHF") != -1)	return(2);
	if (StringFind(mySymbol, "AUDJPY") != -1)	return(3);
	if (StringFind(mySymbol, "AUDNZD") != -1)	return(4);
	if (StringFind(mySymbol, "AUDUSD") != -1)	return(5);
	if (StringFind(mySymbol, "CADCHF") != -1)	return(6);
	if (StringFind(mySymbol, "CADJPY") != -1)	return(7);
	if (StringFind(mySymbol, "CHFJPY") != -1)	return(8);
	if (StringFind(mySymbol, "EURAUD") != -1)	return(9);
	if (StringFind(mySymbol, "EURCAD") != -1)	return(10);
	if (StringFind(mySymbol, "EURCHF") != -1)	return(11);
	if (StringFind(mySymbol, "EURGBP") != -1)	return(12);
	if (StringFind(mySymbol, "EURJPY") != -1)	return(13);
	if (StringFind(mySymbol, "EURNZD") != -1)	return(14);
	if (StringFind(mySymbol, "EURUSD") != -1)	return(15);
	if (StringFind(mySymbol, "GBPAUD") != -1)	return(16);
	if (StringFind(mySymbol, "GBPCAD") != -1)	return(17);
	if (StringFind(mySymbol, "GBPCHF") != -1)	return(18);
	if (StringFind(mySymbol, "GBPJPY") != -1)	return(19);
	if (StringFind(mySymbol, "GBPNZD") != -1)	return(20);
	if (StringFind(mySymbol, "GBPUSD") != -1)	return(21);
	if (StringFind(mySymbol, "NZDCAD") != -1)	return(22);
	if (StringFind(mySymbol, "NZDCHF") != -1)	return(23);
	if (StringFind(mySymbol, "NZDJPY") != -1)	return(24);
	if (StringFind(mySymbol, "NZDUSD") != -1)	return(25);
	if (StringFind(mySymbol, "USDCAD") != -1)	return(26);
	if (StringFind(mySymbol, "USDCHF") != -1)	return(27);
	if (StringFind(mySymbol, "USDJPY") != -1)	return(28);
	if (StringFind(mySymbol, "XAGUSD") != -1)	return(29);
	if (StringFind(mySymbol, "SILVER") != -1)	return(29);
	if (StringFind(mySymbol, "XAUUSD") != -1)	return(30);
	if (StringFind(mySymbol, "GOLD") != -1)		return(30);
	
	// These symbols were added 26Sep10
	if (StringFind(mySymbol, "AUDDKK") != -1)	return(31);
	if (StringFind(mySymbol, "AUDNOK") != -1)	return(32);
	if (StringFind(mySymbol, "AUDSEK") != -1)	return(33);
	if (StringFind(mySymbol, "CHFNOK") != -1)	return(34);
	if (StringFind(mySymbol, "EURDKK") != -1)	return(35);
	if (StringFind(mySymbol, "EURPLN") != -1)	return(36);
	if (StringFind(mySymbol, "EURSEK") != -1)	return(37);
	if (StringFind(mySymbol, "EURSGD") != -1)	return(38);
	if (StringFind(mySymbol, "EURZAR") != -1)	return(39);
	if (StringFind(mySymbol, "GBPNOK") != -1)	return(40);
	if (StringFind(mySymbol, "GBPNZD") != -1)	return(41);
	if (StringFind(mySymbol, "GBPSGD") != -1)	return(42);
	if (StringFind(mySymbol, "NOKJPY") != -1)	return(43);
	if (StringFind(mySymbol, "SEKJPY") != -1)	return(44);
	if (StringFind(mySymbol, "USDAED") != -1)	return(45);
	if (StringFind(mySymbol, "USDBHD") != -1)	return(46);
	if (StringFind(mySymbol, "USDDKK") != -1)	return(47);
	if (StringFind(mySymbol, "USDEGP") != -1)	return(48);
	if (StringFind(mySymbol, "USDHKD") != -1)	return(49);
	if (StringFind(mySymbol, "USDJOD") != -1)	return(50);
	if (StringFind(mySymbol, "USDKWD") != -1)	return(51);
	if (StringFind(mySymbol, "USDMXN") != -1)	return(52);
	if (StringFind(mySymbol, "USDNOK") != -1)	return(53);
	if (StringFind(mySymbol, "USDPLN") != -1)	return(54);
	if (StringFind(mySymbol, "USDQAR") != -1)	return(55);
	if (StringFind(mySymbol, "USDSAR") != -1)	return(56);
	if (StringFind(mySymbol, "USDSEK") != -1)	return(57);
	if (StringFind(mySymbol, "USDSGD") != -1)	return(58);
	if (StringFind(mySymbol, "USDTHB") != -1)	return(59);
	if (StringFind(mySymbol, "USDZAR") != -1)	return(60);
	
	// 11Sep20:
	// Use this as last resort, if we got this far...
	orNonStandardSymbol = true;
	
	// In trying to figure out a better way; for 
	// symbols that are non-standard, came across 
	// code to iterate through the Market list.  
	// Lets try using it for now instead:
	// It appears that the list is alphabetical, 
	// and we can get all symbols (false) or just 
	// the ones in Market Watch (true).
	// This varies broker to broker, but that's fine
	for (int n=0; n < SymbolsTotal(false); n++)
	{
		string name = SymbolName(n, false);
		if (name == symbol)
			break;
	}
	return(n+1);	// Don't use zero
}


//=============================================================================
//  11Sep20:
//  The problem with the solution above is converting back. SymbolVal2String() 
//  is ALMOST never used.  I saw a reference in Trend-Profiteer-Ind.mq4, 
//  Trend-Profiteer.mq4, and ScheduledNewsEA.mq4, as well as a couple others 
//  in unimportant FBLib archives.  Still, cannot design something that can 
//  break, so I devised a primitive solution:
//
//  Any EA/Ind using this would of course have it's own instance of the code, 
//  and would almost* certainly have to call SymbolConst2Val() before 
//  SymbolVal2String(), so if the former cannot find it conventionally, set a 
//  global called orNonStandardSymbol.  That way, we can check it and convert 
//  back the same way.
//
//  *If it's used another way, we risk error, but that's unhedard of so far.
//=============================================================================
string MySymbolVal2String(int val) 
{
	if (orNonStandardSymbol)
	{
		// 11Sep20:
		// Use this if flagged to do so
		
		// In trying to figure out a better way; for 
		// symbols that are non-standard, came across 
		// code to iterate through the Market list.  
		// Lets try using it for now instead:
		// SymbolConst2Val returns the symbol index 
		// so we should only need to return it's name.
		// This varies broker to broker, but not much 
		// to be done about that.
		return(SymbolName(val-1, false));
	}
	
	// Going out on a limb here and guessing that if the name we intended to return 
	// is contained in the Symbol() name for this chart, then lets return the actual 
	// Symbol() name.  e.g. If the Symbol was EURUSD.lmax, and SymbolConst2Val() 
	// returned 15, then when we convert 15 back, if the chart pair contains "EURUSD", 
	// then lets return the Symbol (EURUSD.lmax instead of just EURUSD). 
	if (val == 1) 	return((StringFind(Symbol(), "AUDCAD") != -1) ? Symbol() : "AUDCAD");
	if (val == 2)	return((StringFind(Symbol(), "AUDCHF") != -1) ? Symbol() : "AUDCHF");
	if (val == 3) 	return((StringFind(Symbol(), "AUDJPY") != -1) ? Symbol() : "AUDJPY");
	if (val == 4) 	return((StringFind(Symbol(), "AUDNZD") != -1) ? Symbol() : "AUDNZD");
	if (val == 5) 	return((StringFind(Symbol(), "AUDUSD") != -1) ? Symbol() : "AUDUSD");
	if (val == 6)	return((StringFind(Symbol(), "CADCHF") != -1) ? Symbol() : "CADCHF");
	if (val == 7) 	return((StringFind(Symbol(), "CADJPY") != -1) ? Symbol() : "CADJPY");
	if (val == 8) 	return((StringFind(Symbol(), "CHFJPY") != -1) ? Symbol() : "CHFJPY");
	if (val == 9) 	return((StringFind(Symbol(), "EURAUD") != -1) ? Symbol() : "EURAUD");
	if (val == 10) 	return((StringFind(Symbol(), "EURCAD") != -1) ? Symbol() : "EURCAD");
	if (val == 11) 	return((StringFind(Symbol(), "EURCHF") != -1) ? Symbol() : "EURCHF");
	if (val == 12) 	return((StringFind(Symbol(), "EURGBP") != -1) ? Symbol() : "EURGBP");
	if (val == 13) 	return((StringFind(Symbol(), "EURJPY") != -1) ? Symbol() : "EURJPY");
	if (val == 14)	return((StringFind(Symbol(), "EURNZD") != -1) ? Symbol() : "EURNZD");
	if (val == 15) 	return((StringFind(Symbol(), "EURUSD") != -1) ? Symbol() : "EURUSD");
	if (val == 16)	return((StringFind(Symbol(), "GBPAUD") != -1) ? Symbol() : "GBPAUD");
	if (val == 17)	return((StringFind(Symbol(), "GBPCAD") != -1) ? Symbol() : "GBPCAD");
	if (val == 18) 	return((StringFind(Symbol(), "GBPCHF") != -1) ? Symbol() : "GBPCHF");
	if (val == 19) 	return((StringFind(Symbol(), "GBPJPY") != -1) ? Symbol() : "GBPJPY");
	if (val == 20)	return((StringFind(Symbol(), "GBPNZD") != -1) ? Symbol() : "GBPNZD");
	if (val == 21) 	return((StringFind(Symbol(), "GBPUSD") != -1) ? Symbol() : "GBPUSD");
	if (val == 22)	return((StringFind(Symbol(), "NZDCAD") != -1) ? Symbol() : "NZDCAD");
	if (val == 23)	return((StringFind(Symbol(), "NZDCHF") != -1) ? Symbol() : "NZDCHF");
	if (val == 24) 	return((StringFind(Symbol(), "NZDJPY") != -1) ? Symbol() : "NZDJPY");
	if (val == 25) 	return((StringFind(Symbol(), "NZDUSD") != -1) ? Symbol() : "NZDUSD");
	if (val == 26) 	return((StringFind(Symbol(), "USDCAD") != -1) ? Symbol() : "USDCAD");
	if (val == 27) 	return((StringFind(Symbol(), "USDCHF") != -1) ? Symbol() : "USDCHF");
	if (val == 28)	return((StringFind(Symbol(), "USDJPY") != -1) ? Symbol() : "USDJPY");
	if (val == 29)	return((StringFind(Symbol(), "XAGUSD") != -1  ||  
							StringFind(Symbol(), "SILVER") != -1) ? Symbol() : "XAGUSD");
	if (val == 30)	return((StringFind(Symbol(), "XAUUSD") != -1  ||  
							StringFind(Symbol(), "GOLD")   != -1) ? Symbol() : "XAUUSD");
	
	// These symbols were added 26Sep10
	if (val == 31)	return((StringFind(Symbol(), "AUDDKK") != -1) ? Symbol() : "AUDDKK");
	if (val == 32)	return((StringFind(Symbol(), "AUDNOK") != -1) ? Symbol() : "AUDNOK");
	if (val == 33)	return((StringFind(Symbol(), "AUDSEK") != -1) ? Symbol() : "AUDSEK");
	if (val == 34)	return((StringFind(Symbol(), "CHFNOK") != -1) ? Symbol() : "CHFNOK");
	if (val == 35)	return((StringFind(Symbol(), "EURDKK") != -1) ? Symbol() : "EURDKK");
	if (val == 36)	return((StringFind(Symbol(), "EURPLN") != -1) ? Symbol() : "EURPLN");
	if (val == 37)	return((StringFind(Symbol(), "EURSEK") != -1) ? Symbol() : "EURSEK");
	if (val == 38)	return((StringFind(Symbol(), "EURSGD") != -1) ? Symbol() : "EURSGD");
	if (val == 39)	return((StringFind(Symbol(), "EURZAR") != -1) ? Symbol() : "EURZAR");
	if (val == 40)	return((StringFind(Symbol(), "GBPNOK") != -1) ? Symbol() : "GBPNOK");
	if (val == 41)	return((StringFind(Symbol(), "GBPNZD") != -1) ? Symbol() : "GBPNZD");
	if (val == 42)	return((StringFind(Symbol(), "GBPSGD") != -1) ? Symbol() : "GBPSGD");
	if (val == 43)	return((StringFind(Symbol(), "NOKJPY") != -1) ? Symbol() : "NOKJPY");
	if (val == 44)	return((StringFind(Symbol(), "SEKJPY") != -1) ? Symbol() : "SEKJPY");
	if (val == 45)	return((StringFind(Symbol(), "USDAED") != -1) ? Symbol() : "USDAED");
	if (val == 46)	return((StringFind(Symbol(), "USDBHD") != -1) ? Symbol() : "USDBHD");
	if (val == 47)	return((StringFind(Symbol(), "USDDKK") != -1) ? Symbol() : "USDDKK");
	if (val == 48)	return((StringFind(Symbol(), "USDEGP") != -1) ? Symbol() : "USDEGP");
	if (val == 49)	return((StringFind(Symbol(), "USDHKD") != -1) ? Symbol() : "USDHKD");
	if (val == 50)	return((StringFind(Symbol(), "USDJOD") != -1) ? Symbol() : "USDJOD");
	if (val == 51)	return((StringFind(Symbol(), "USDKWD") != -1) ? Symbol() : "USDKWD");
	if (val == 52)	return((StringFind(Symbol(), "USDMXN") != -1) ? Symbol() : "USDMXN");
	if (val == 53)	return((StringFind(Symbol(), "USDNOK") != -1) ? Symbol() : "USDNOK");
	if (val == 54)	return((StringFind(Symbol(), "USDPLN") != -1) ? Symbol() : "USDPLN");
	if (val == 55)	return((StringFind(Symbol(), "USDQAR") != -1) ? Symbol() : "USDQAR");
	if (val == 56)	return((StringFind(Symbol(), "USDSAR") != -1) ? Symbol() : "USDSAR");
	if (val == 57)	return((StringFind(Symbol(), "USDSEK") != -1) ? Symbol() : "USDSEK");
	if (val == 58)	return((StringFind(Symbol(), "USDSGD") != -1) ? Symbol() : "USDSGD");
	if (val == 59)	return((StringFind(Symbol(), "USDTHB") != -1) ? Symbol() : "USDTHB");
	if (val == 60)	return((StringFind(Symbol(), "USDZAR") != -1) ? Symbol() : "USDZAR");
	return("Unknown");
}
