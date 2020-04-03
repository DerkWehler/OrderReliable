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
//  Changed gRetryAttempts to 5 (was 10)
//
//  v37, 5Aug19:
//  Changed OrderReliablePrint to take calling function name as 1st param
//  Reprogrammed SleepRandomTime() to be less cryptic. Added SleepAveTime, 
//  set to 50ms. Got rid of gSleepTime & gSleepMaximum.
//
//  v38, 26Mar20:
//  For the add spread to comment, reduced by 2 chars, cause not much room
//
//===========================================================================

#property copyright "Copyright © 2006, Derk Wehler"
#property link      "derkwehler@gmail.com"

#include <stdlib.mqh>
#include <stderror.mqh>

string 	OrderReliableVersion = "v38";

int 	gRetryAttempts 		= 5;
double 	gSleepAveTime 		= 50.0;

int 	gErrorLevel 		= 3;

bool	gUseLimitToMarket 	= false;
bool	gUseForTesting 		= false;
bool	gAddSpreadToComment	= false;


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
	string fn = "OrderSendReliable[]";
	int ticket = -1;
	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!gUseForTesting)
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
	double point, M;
	double bid, ask;
	double sl, tp;
	double priceNow;
	double hasSlippedBy;
	
	GetOrderDetails(0, symbol, cmd, digits, point, sl, tp, bid, ask, false);
	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	
	OrderReliablePrint(fn, "");
	OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
	OrderReliablePrint(fn, "Attempted " + OrderTypeToString(cmd) + " " + symbol + ": " + DoubleToStr(volume, 3) + " lots @" + 
	                   DoubleToStr(price, digits+1) + ", sl:" + DoubleToStr(stoploss, digits+1) + ", tp:" + DoubleToStr(takeprofit, digits+1));


	// Normalize all price / stoploss / takeprofit to the proper # of digits.
	price = NormalizeDouble(price, digits);
	stoploss = NormalizeDouble(stoploss, digits);
	takeprofit = NormalizeDouble(takeprofit, digits);

	// Check stop levels, adjust if necessary
	EnsureValidStops(symbol, cmd, price, stoploss, takeprofit);

	int cnt;
	GetLastError(); // clear the global variable.
	int err = 0;
	bool exit_loop = false;
	bool limit_to_market = false;
	bool fixed_invalid_price = false;

	// Concatenate to comment if enabled
	double symSpr = MarketInfo(symbol, MODE_ASK) - MarketInfo(symbol, MODE_BID);
	if (gAddSpreadToComment)
		comment = comment + ", Spr:" + DoubleToStr(symSpr / adjPoint, 1);
		
	// Limit/Stop order...............................................................
	if (cmd > OP_SELL)
	{
		cnt = 0;
		while (!exit_loop)
		{
			// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =
			// Calculating our own slippage internally should not need to be done for pending orders; see market orders below
			// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =

			//OrderReliablePrint(fn, "About to call OrderSend(), comment = " + comment);
			ticket = OrderSend(symbol, cmd, volume, price, slippage, stoploss,
			                   takeprofit, comment, magic, expiration, arrow_color);
			err = GetLastError();

			switch (err)
			{
				case ERR_NO_ERROR:
					exit_loop = true;
					break;

				// retryable errors
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_TRADE_CONTEXT_BUSY:
				case ERR_TRADE_TIMEOUT:
				case ERR_TRADE_DISABLED:
				case ERR_PRICE_CHANGED:
				case ERR_REQUOTE:
					cnt++;
					break;

				case ERR_INVALID_PRICE:
				case ERR_INVALID_STOPS:
					limit_to_market = EnsureValidPendPrice(err, fixed_invalid_price, symbol, cmd, price, 
														   stoploss, takeprofit, slippage, point, digits);
					if (limit_to_market) 
						exit_loop = true;
					cnt++;
					break;

				case ERR_INVALID_TRADE_PARAMETERS:
				default:
					// an apparently serious error.
					exit_loop = true;
					break;

			}  // end switch

			if (cnt > gRetryAttempts)
				exit_loop = true;

			if (exit_loop)
			{
				if (!limit_to_market)
				{
					if (err != ERR_NO_ERROR  &&  err != ERR_NO_RESULT)
						OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
					else if (cnt > gRetryAttempts)
						OrderReliablePrint(fn, "Retry attempts maxed at " + gRetryAttempts);
				}
			}
			else
			{
				OrderReliablePrint(fn, "Result of attempt " + cnt + " of " + gRetryAttempts + ": Retryable error: " + OrderReliableErrTxt(err));
				OrderReliablePrint(fn, "Current Bid = " + MarketInfo(symbol, MODE_BID) + ", Current Ask = " + MarketInfo(symbol, MODE_ASK));
				OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
				SleepRandomTime();
				RefreshRates();
			}
		}

		// We have now exited from loop.
		if (err == ERR_NO_ERROR  ||  err == ERR_NO_RESULT)
		{
			OrderReliablePrint(fn, "Ticket #" + ticket + ": Successful " + OrderTypeToString(cmd) + " order placed with comment = " + comment + ", details follow.");
			if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
				OrderReliablePrint(fn, "Could Not Select Ticket #" + ticket);
			OrderPrint();
			OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
			OrderReliablePrint(fn, "");
			return(ticket); // SUCCESS!
		}
		if (!limit_to_market)
		{
			OrderReliablePrint(fn, "Failed to execute stop or limit order after " + gRetryAttempts + " retries");
			OrderReliablePrint(fn, "Failed trade: " + OrderTypeToString(cmd) + ", " + DoubleToStr(volume, 2) + " lots,  " + symbol +
			                   "@" + price + ", sl@" + stoploss + ", tp@" + takeprofit);
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
		if (cmd == OP_BUY)	price = ask;
		else 				price = bid;
	}

	// We now have a market order.
	err = GetLastError(); // so we clear the global variable.
	err = 0;
	ticket = -1;
	exit_loop = false;


	// Market order..........................................................
	if (cmd == OP_BUY  ||  cmd == OP_SELL)
	{
		cnt = 0;
		while (!exit_loop)
		{
			// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =
			// Get current price and calculate slippage
			RefreshRates();
			if (cmd == OP_BUY)
			{
				M = 1.0;
				priceNow = NormalizeDouble(MarketInfo(symbol, MODE_ASK), MarketInfo(symbol, MODE_DIGITS));	// Open @ Ask
				hasSlippedBy = (priceNow - price) / point;	// (Adjusted Point)
			}
			else if (cmd == OP_SELL)
			{
				M = -1.0;
				priceNow = NormalizeDouble(MarketInfo(symbol, MODE_BID), MarketInfo(symbol, MODE_DIGITS));	// Open @ Bid
				hasSlippedBy = (price - priceNow) / point;	// (Adjusted Point)
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
					if (stoploss != 0)		stoploss += M * hasSlippedBy;
					if (takeprofit != 0)	takeprofit += M * hasSlippedBy;
					OrderReliablePrint(fn, "Actual Price (Ask for buy, Bid for sell) = " + DoubleToStr(priceNow, Digits+1) + "; Requested Price = " + DoubleToStr(price, Digits) + "; Slippage from Requested Price = " + DoubleToStr(hasSlippedBy, 1) + " pips (\'positive slippage\').  Attempting order at market");
				}
				//OrderReliablePrint(fn, "About to call OrderSend(), comment = " + comment);
				ticket = OrderSend(symbol, cmd, volume, priceNow, (slippage - hasSlippedBy), 
								   stoploss, takeprofit, comment, magic,	expiration, arrow_color);
				err = GetLastError();
			}
			// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =

			switch (err)
			{
				case ERR_NO_ERROR:
					exit_loop = true;
					break;

				case ERR_INVALID_PRICE:
					if (cmd == OP_BUY)
						OrderReliablePrint(fn, "INVALID PRICE ERROR - Requested Price: " + DoubleToStr(price, Digits) + "; Ask = " + DoubleToStr(MarketInfo(symbol, MODE_ASK), Digits));
					else
						OrderReliablePrint(fn, "INVALID PRICE ERROR - Requested Price: " + DoubleToStr(price, Digits) + "; Bid = " + DoubleToStr(MarketInfo(symbol, MODE_BID), Digits));
					cnt++; // a retryable error
					break;
					
				case ERR_INVALID_STOPS:
					OrderReliablePrint(fn, "INVALID STOPS on attempted " + OrderTypeToString(cmd) + " : " + DoubleToStr(volume, 2) + " lots " + " @ " + DoubleToStr(price, Digits) + ", SL = " + DoubleToStr(stoploss, Digits) + ", TP = " + DoubleToStr(takeprofit, Digits));
					cnt++; // a retryable error
					break;
					
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_TRADE_CONTEXT_BUSY:
				case ERR_TRADE_TIMEOUT:
				case ERR_TRADE_DISABLED:
				case ERR_PRICE_CHANGED:
				case ERR_REQUOTE:
					cnt++; // a retryable error
					break;

				default:
					// an apparently serious, unretryable error.
					exit_loop = true;
					break;
			}  

			if (cnt > gRetryAttempts)
				exit_loop = true;

			if (exit_loop)
			{
				if (err != ERR_NO_ERROR  &&  err != ERR_NO_RESULT)
					OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
				if (cnt > gRetryAttempts)
					OrderReliablePrint(fn, "Retry attempts maxed at " + gRetryAttempts);
			}
			else
			{
				OrderReliablePrint(fn, "Result of attempt " + cnt + " of " + gRetryAttempts + ": Retryable error: " + OrderReliableErrTxt(err));
				OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
				SleepRandomTime();
				RefreshRates();
			}
		}

		// We have now exited from loop; if successful, return ticket #
		if (err == ERR_NO_ERROR  ||  err == ERR_NO_RESULT)
		{
			OrderReliablePrint(fn, "Ticket #" + ticket + ": Successful " + OrderTypeToString(cmd) + " order placed with comment = " + comment + ", details follow.");
			if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
				OrderReliablePrint(fn, "Could Not Select Ticket #" + ticket);
			OrderPrint();
			OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
			OrderReliablePrint(fn, "");
			return(ticket); // SUCCESS!
		}
		
		// If not successful, log and return -1
		OrderReliablePrint(fn, "Failed to execute OP_BUY/OP_SELL, after " + gRetryAttempts + " retries");
		OrderReliablePrint(fn, "Failed trade: " + OrderTypeToString(cmd) + " " + DoubleToStr(volume, 2) + " lots  " + symbol +
		                   "@" + price + " tp@" + takeprofit + " sl@" + stoploss);
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
	string fn = "OrderSendReliableMKT[]";
	int ticket = -1;
	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!gUseForTesting)
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
	bool exit_loop = false;

	if ((cmd == OP_BUY) || (cmd == OP_SELL))
	{
		cnt = 0;
		while (!exit_loop)
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
					exit_loop = true;
					break;

				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_INVALID_PRICE:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_TRADE_CONTEXT_BUSY:
				case ERR_TRADE_TIMEOUT:
				case ERR_TRADE_DISABLED:
					cnt++; // a retryable error
					break;

				case ERR_PRICE_CHANGED:
				case ERR_REQUOTE:
					// Paul Hampton-Smith removed RefreshRates() here and used MarketInfo() above instead
					continue; // we can apparently retry immediately according to MT docs.

				default:
					// an apparently serious, unretryable error.
					exit_loop = true;
					break;

			}  // end switch

			if (cnt > gRetryAttempts)
				exit_loop = true;

			if (!exit_loop)
			{
				OrderReliablePrint(fn, "Result of attempt " + cnt + " of " + gRetryAttempts + ": Retryable error: " + OrderReliableErrTxt(err));
				OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
				SleepRandomTime();
			}
			else
			{
				if (err != ERR_NO_ERROR  &&  err != ERR_NO_RESULT)
				{
					OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
				}
				if (cnt > gRetryAttempts)
				{
					OrderReliablePrint(fn, "Retry attempts maxed at " + gRetryAttempts);
				}
			}
		}

		// we have now exited from loop.
		if (err == ERR_NO_ERROR  ||  err == ERR_NO_RESULT)
		{
			OrderReliablePrint(fn, "Ticket #" + ticket + ": Successful " + OrderTypeToString(cmd) + " order placed, details follow.");
			OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES);
			OrderPrint();
			OrderReliablePrint(fn, "•  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •  •");
			OrderReliablePrint(fn, "");
			return(ticket); // SUCCESS!
		}
		OrderReliablePrint(fn, "Failed to execute OP_BUY/OP_SELL, after " + gRetryAttempts + " retries");
		OrderReliablePrint(fn, "Failed trade: " + OrderTypeToString(cmd) + " " + DoubleToStr(volume, 2) + " lots  " + symbol +
		                   "@" + price + " tp@" + takeprofit + " sl@" + stoploss);
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
	string fn = "OrderSendReliable2Step[]";
	int ticket = -1;
	double slipped = 0;
	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!gUseForTesting)
	{
		if (IsOptimization()  ||  IsTesting())
		{
			ticket = OrderSend(symbol, cmd, volume, price, slippage, 0, 0, 
							   comment, magic, 0, arrow_color);

			if (!OrderModify(ticket, price, stoploss, takeprofit, expiration, arrow_color))
				OrderReliablePrint(fn, "Order Modify of Ticket #" + ticket + " FAILED");
			
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
				slipped = OrderOpenPrice() - price;
				theOpenPrice = OrderOpenPrice();
			}
			else
				OrderReliablePrint(fn, "Failed to select ticket #" + ticket + " after successful 2step placement; cannot recalculate SL & TP");
			if (slipped > 0)
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
	string fn = "OrderModifyReliable[]";
	bool result = false;
	bool non_retryable_error = false;

	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!gUseForTesting)
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
	OrderReliablePrint(fn, "Attempted modify of #" + ticket + ", " + OrderTypeToString(type) + ", price:" + DoubleToStr(price, digits+1) +
	                   ", sl:" + DoubleToStr(stoploss, digits+1) + ", tp:" + DoubleToStr(takeprofit, digits+1) + 
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
	bool exit_loop = false;

	while (!exit_loop)
	{
		result = OrderModify(ticket, price, stoploss,
		                     takeprofit, expiration, arrow_color);
		err = GetLastError();

		if (result == true)
			exit_loop = true;
		else
		{
			switch (err)
			{
				case ERR_NO_ERROR:
					exit_loop = true;
					OrderReliablePrint(fn, "ERR_NO_ERROR received, but OrderClose() returned false; exiting");
					break;

				case ERR_NO_RESULT:
					// Modification to same value as before
					// See below for reported result
					exit_loop = true;
					break;

				// Shouldn't be any reason stops are invalid (and yet I've seen it); try again
				case ERR_INVALID_STOPS:	
					OrderReliablePrint(fn, "OrderModifyReliable, ERR_INVALID_STOPS, Broker\'s Min Stop Level (in pips) = " + DoubleToStr(MarketInfo(symbol, MODE_STOPLEVEL) * Point / AdjPoint(symbol), 1));
//					EnsureValidStops(symbol, price, stoploss, takeprofit);
				case ERR_COMMON_ERROR:
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_TOO_FREQUENT_REQUESTS:
				case ERR_TRADE_TIMEOUT:		// for modify this is a retryable error, I hope.
				case ERR_INVALID_PRICE:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_TOO_MANY_REQUESTS:
				case ERR_TRADE_CONTEXT_BUSY:
				case ERR_TRADE_DISABLED:
					cnt++; 	// a retryable error
					break;

				case ERR_TRADE_MODIFY_DENIED:
					// This one may be important; have to Ensure Valid Stops AND valid price (for pends)
					break;
				
				case ERR_PRICE_CHANGED:
				case ERR_REQUOTE:
					RefreshRates();
					continue; 	// we can apparently retry immediately according to MT docs.

				default:
					// an apparently serious, unretryable error.
					exit_loop = true;
					non_retryable_error = true;
					break;

			}  // end switch
		}

		if (cnt > gRetryAttempts)
			exit_loop = true;

		if (!exit_loop)
		{
			OrderReliablePrint(fn, "Result of attempt " + cnt + " of " + gRetryAttempts + ": Retryable error: " + OrderReliableErrTxt(err));
			OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
			SleepRandomTime();
			RefreshRates();
		}
		else
		{
			if (cnt > gRetryAttempts)
				OrderReliablePrint(fn, "Retry attempts maxed at " + gRetryAttempts);
			else if (non_retryable_error)
				OrderReliablePrint(fn, "Non-retryable error: "  + OrderReliableErrTxt(err));
		}
	}

	// we have now exited from loop.
	if (err == ERR_NO_RESULT)
	{
		OrderReliablePrint(fn, "Server reported modify order did not actually change parameters.");
		OrderReliablePrint(fn, "Redundant modification: " + ticket + " " + symbol +
		                   "@" + price + " tp@" + takeprofit + " sl@" + stoploss);
		OrderReliablePrint(fn, "Suggest modifying code logic to avoid.");
	}
	
	if (result)
	{
		OrderReliablePrint(fn, "Ticket #" + ticket + ": Modification successful, updated trade details follow.");
		if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
			OrderReliablePrint(fn, "Could Not Select Ticket #" + ticket);
		OrderPrint();
	}
	else
	{
		OrderReliablePrint(fn, "Failed to execute modify after " + gRetryAttempts + " retries");
		OrderReliablePrint(fn, "Failed modification: #"  + ticket + ", " + OrderTypeToString(type) + ", " + symbol +
	                   	"@" + price + " sl@" + stoploss + " tp@" + takeprofit);
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
	string fn = "OrderCloseReliable[]";
	bool result = false;
	bool non_retryable_error = false;
	
	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!gUseForTesting)
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
	OrderReliablePrint(fn, "Attempted close of #" + ticket + " initial price:" + DoubleToStr(price, digits+1) +
	                   " lots:" + DoubleToStr(volume, 3) + " slippage:" + slippage);


	if (type != OP_BUY && type != OP_SELL)
	{
		OrderReliablePrint(fn, "Error: Trying to close ticket #" + ticket + ", which is " + OrderTypeToString(type) + ", not OP_BUY or OP_SELL");
		return(false);
	}


	int cnt = 0;
	int err = GetLastError(); // so we clear the global variable.
	err = 0;
	bool exit_loop = false;
	double priceNow;
	double hasSlippedBy;

	while (!exit_loop)
	{
		// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =
		// Get current price and calculate slippage
		RefreshRates();
		if (type == OP_BUY)
		{
			priceNow = NormalizeDouble(MarketInfo(symbol, MODE_BID), MarketInfo(symbol, MODE_DIGITS));	// Close @ Bid
			hasSlippedBy = (price - priceNow) / point;	// (Adjusted Point)
		}
		else if (type == OP_SELL)
		{
			priceNow = NormalizeDouble(MarketInfo(symbol, MODE_ASK), MarketInfo(symbol, MODE_DIGITS));	// Close @ Ask
			hasSlippedBy = (priceNow - price) / point;	// (Adjusted Point)
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
			result = OrderClose(ticket, volume, priceNow, (slippage - hasSlippedBy), arrow_color);
			err = GetLastError();
		}
		// = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : = : =

		if (result == true)
			exit_loop = true;
		else
		{
			switch (err)
			{
				case ERR_NO_ERROR:
					exit_loop = true;
					OrderReliablePrint(fn, "ERR_NO_ERROR received, but OrderClose() returned false; exiting");
					OrderReliablePrint(fn, "If order did not actually close, error code is apparently wrong");
					break;

				case ERR_NO_RESULT:
					exit_loop = true;
					OrderReliablePrint(fn, "ERR_NO_RESULT received, but OrderClose() returned false; exiting");
					OrderReliablePrint(fn, "If order did not actually close, error code is apparently wrong");
					break;

				case ERR_INVALID_PRICE:
					OrderReliablePrint(fn, "ERR_INVALID_PRICE received, but should not occur since we are refreshing rates");
					cnt++; 	// a retryable error
					break;

				case ERR_PRICE_CHANGED:
				case ERR_COMMON_ERROR:
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_TOO_FREQUENT_REQUESTS:
				case ERR_TRADE_TIMEOUT:		// for close this is a retryable error, I hope.
				case ERR_TRADE_DISABLED:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_REQUOTE:
				case ERR_TOO_MANY_REQUESTS:	
				case ERR_TRADE_CONTEXT_BUSY:
					cnt++; 	// a retryable error
					break;

				default:
					// Any other error is an apparently serious, unretryable error.
					exit_loop = true;
					non_retryable_error = true;
					break;

			}  // end switch
		}

		if (cnt > gRetryAttempts)
			exit_loop = true;

		if (exit_loop)
		{
			if (cnt > gRetryAttempts)
				OrderReliablePrint(fn, "Retry attempts maxed at " + gRetryAttempts);
			else if (non_retryable_error)
				OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
		}
		else
		{
			OrderReliablePrint(fn, "Result of attempt " + cnt + " of " + gRetryAttempts + ": Retryable error: " + OrderReliableErrTxt(err));
			OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
			SleepRandomTime();
		}
	}

	// We have now exited from loop
	if (result  ||  err == ERR_NO_RESULT  ||  err == ERR_NO_ERROR)
	{
		if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
			OrderReliablePrint(fn, "Successful close of Ticket #" + ticket + "     [ Last error: " + OrderReliableErrTxt(err) + " ]");
		else if (OrderCloseTime() > 0)	// Then it closed ok
			OrderReliablePrint(fn, "Successful close of Ticket #" + ticket + "     [ Last error: " + OrderReliableErrTxt(err) + " ]");
		else
		{
			OrderReliablePrint(fn, "Close result reported success (or failure, but w/ERR_NO_ERROR); yet order remains!  Must re-try close from EA logic!");
			OrderReliablePrint(fn, "Close Failed: Ticket #" + ticket + ", Price: " +
		                   		price + ", Slippage: " + slippage);
			OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
			result = false;
		}
	}
	else
	{
		OrderReliablePrint(fn, "Failed to execute close after " + (cnt-1) + " retries");
		OrderReliablePrint(fn, "Failed close: Ticket #" + ticket + " @ Price: " + priceNow + 
	                   	   " (Requested Price: " + price + "), Slippage: " + slippage);
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
	string fn = "OrderCloseReliableMKT[]";
	bool result = false;
	bool non_retryable_error = false;
	
	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!gUseForTesting)
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
	OrderReliablePrint(fn, "Attempted close of #" + ticket + " initial price:" + DoubleToStr(price, digits+1) +
	                   " lots:" + DoubleToStr(price, 3) + " slippage:" + slippage);


	if (type != OP_BUY && type != OP_SELL)
	{
		OrderReliablePrint(fn, "Error: Trying to close ticket #" + ticket + ", which is " + OrderTypeToString(type) + ", not OP_BUY or OP_SELL");
		return(false);
	}


	int cnt = 0;
	int err = GetLastError(); // so we clear the global variable.
	err = 0;
	bool exit_loop = false;
	double pnow;
	int slippagenow;

	while (!exit_loop)
	{
		if (type == OP_BUY)
		{
			pnow = NormalizeDouble(MarketInfo(symbol, MODE_ASK), MarketInfo(symbol, MODE_DIGITS)); // we are buying at Ask
			if (pnow > price)
			{
				// Do not allow slippage to go negative; will cause error
				slippagenow = MathMax(0, slippage - (pnow - price) / point);
			}
		}
		else if (type == OP_SELL)
		{
			pnow = NormalizeDouble(MarketInfo(symbol, MODE_BID), MarketInfo(symbol, MODE_DIGITS)); // we are buying at Ask
			if (pnow < price)
			{
				// Do not allow slippage to go negative; will cause error
				slippagenow = MathMax(0, slippage - (price - pnow) / point);
			}
		}

		result = OrderClose(ticket, volume, pnow, slippagenow, arrow_color);
		err = GetLastError();

		if (result == true)
			exit_loop = true;
		else
		{
			switch (err)
			{
				case ERR_NO_ERROR:
					exit_loop = true;
					OrderReliablePrint(fn, "ERR_NO_ERROR received, but OrderClose() returned false; exiting");
					break;

				case ERR_NO_RESULT:
					exit_loop = true;
					OrderReliablePrint(fn, "ERR_NO_RESULT received, but OrderClose() returned false; exiting");
					break;

				case ERR_COMMON_ERROR:
				case ERR_SERVER_BUSY:
				case ERR_NO_CONNECTION:
				case ERR_TOO_FREQUENT_REQUESTS:
				case ERR_TRADE_TIMEOUT:		// for close this is a retryable error, I hope.
				case ERR_TRADE_DISABLED:
				case ERR_PRICE_CHANGED:
				case ERR_INVALID_PRICE:
				case ERR_OFF_QUOTES:
				case ERR_BROKER_BUSY:
				case ERR_REQUOTE:
				case ERR_TOO_MANY_REQUESTS:	
				case ERR_TRADE_CONTEXT_BUSY:
					cnt++; 	// a retryable error
					break;

				default:
					// Any other error is an apparently serious, unretryable error.
					exit_loop = true;
					non_retryable_error = true;
					break;

			}  // end switch
		}

		if (cnt > gRetryAttempts)
			exit_loop = true;

		if (!exit_loop)
		{
			OrderReliablePrint(fn, "Result of attempt " + cnt + " of " + gRetryAttempts + ": Retryable error: " + OrderReliableErrTxt(err));
			OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
			SleepRandomTime();
		}

		if (exit_loop)
		{
			if (cnt > gRetryAttempts)
				OrderReliablePrint(fn, "Retry attempts maxed at " + gRetryAttempts);
			else if (non_retryable_error)
				OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
		}
	}

	// we have now exited from loop.
	if (result)
	{
		if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
			OrderReliablePrint(fn, "Successful close of Ticket #" + ticket + "     [ Last error: " + OrderReliableErrTxt(err) + " ]");
		else if (OrderCloseTime() > 0)	// Then it closed ok
			OrderReliablePrint(fn, "Successful close of Ticket #" + ticket + "     [ Last error: " + OrderReliableErrTxt(err) + " ]");
		else
		{
			OrderReliablePrint(fn, "Close result reported success, but order remains!  Must re-try close from EA logic!");
			OrderReliablePrint(fn, "Close Failed: Ticket #" + ticket + ", Price: " +
		                   		price + ", Slippage: " + slippage);
			OrderReliablePrint(fn, "Last error: " + OrderReliableErrTxt(err));
			result = false;
		}
	}
	else
	{
		OrderReliablePrint(fn, "Failed to execute close after " + gRetryAttempts + " retries");
		OrderReliablePrint(fn, "Failed close: Ticket #" + ticket + " @ Price: " +
	                   		pnow + " (Initial Price: " + price + "), Slippage: " + 
	                   		slippagenow + " (Initial Slippage: " + slippage + ")");
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
	string fn = "OrderDeleteReliable[]";
	bool result = false;
	bool non_retryable_error = false;

	// ========================================================================
	// If testing or optimizing, there is no need to use this lib, as the 
	// orders are not real-world, and always get placed optimally.  By 
	// refactoring this option to be in this library, one no longer needs 
	// to create similar code in each EA.
	if (!gUseForTesting)
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
	OrderReliablePrint(fn, "Attempted deletion of pending order, #" + ticket);
	

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
		OrderReliablePrint(fn, "error: Trying to close ticket #" + ticket +
		                   ", which is " + OrderTypeToString(type) +
		                   ", not OP_BUYSTOP, OP_SELLSTOP, OP_BUYLIMIT, or OP_SELLLIMIT");
		return(false);
	}


	int cnt = 0;
	int err = GetLastError(); // so we clear the global variable.
	err = 0;
	bool exit_loop = false;

	while (!exit_loop)
	{
		result = OrderDelete(ticket, clr);
		err = GetLastError();

		if (result == true)
			exit_loop = true;
		else
		{
			switch (err)
			{
				case ERR_NO_ERROR:
					exit_loop = true;
					OrderReliablePrint(fn, "ERR_NO_ERROR received, but OrderDelete() returned false; exiting");
					break;

				case ERR_NO_RESULT:
					exit_loop = true;
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
					cnt++; 	// a retryable error
					break;

				default:	// Any other error is an apparently serious, unretryable error.
					exit_loop = true;
					non_retryable_error = true;
					break;

			}  // end switch
		}

		if (cnt > gRetryAttempts)
			exit_loop = true;

		if (!exit_loop)
		{
			OrderReliablePrint(fn, "Result of attempt " + cnt + " of " + gRetryAttempts + ": Retryable error: " + OrderReliableErrTxt(err));
			OrderReliablePrint(fn, "~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~  ~");
			SleepRandomTime();
		}
		else
		{
			if (cnt > gRetryAttempts)
				OrderReliablePrint(fn, "Retry attempts maxed at " + gRetryAttempts);
			else if (non_retryable_error)
				OrderReliablePrint(fn, "Non-retryable error: " + OrderReliableErrTxt(err));
		}
	}

	// we have now exited from loop.
	if (result)
	{
		OrderReliablePrint(fn, "Successful deletion of Ticket #" + ticket);
		OrderReliablePrint(fn, "º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º  º");
		return(true); // SUCCESS!
	}
	else
	{
		OrderReliablePrint(fn, "Failed to execute delete after " + gRetryAttempts + " retries");
		OrderReliablePrint(fn, "Failed deletion: Ticket #" + ticket);
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
	return (err + "  ::  " + ErrorDescription(err));
}


// Defaut level is 3
// Use level = 1 to Print all but "Retry" messages
// Use level = 0 to Print nothing
void OrderReliableSetErrorLevel(int level)
{
	gErrorLevel = level;
}


void OrderReliablePrint(string f, string s)
{
	// Print to log prepended with stuff;
	if (gErrorLevel >= 99 || (!(IsTesting() || IsOptimization())))
	{
		if (gErrorLevel > 0)
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
	return("None (" + type + ")");
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
	string fn = "EnsureValidStops[]";
	
	double point = MarketInfo(symbol, MODE_POINT);
	
	// We only use point for StopLevel, and StopLevel is reported as 10 times
	// what you expect on a 5-digit broker, so leave it as is.
	//if (point == 0.001  ||  point == 0.00001)
	//	point *= 10;
		
	double 	orig_sl = sl;
	double 	orig_tp = tp;
	double 	new_sl, new_tp;
	int 	min_stop_level = MarketInfo(symbol, MODE_STOPLEVEL);
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
		sl = NormalizeDouble(sl, MarketInfo(symbol, MODE_DIGITS));
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
			tp = NormalizeDouble(tp, MarketInfo(symbol, MODE_DIGITS));
		}
	}
	
	// notify if changed
	if (sl != orig_sl)
		OrderReliablePrint(fn, "SL was too close to brokers min distance (" + min_stop_level + "); moved SL to: " + sl);
	if (tp != orig_tp)
		OrderReliablePrint(fn, "TP was too close to brokers min distance (" + min_stop_level + "); moved TP to: " + tp);
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
//  If gUseLimitToMarket is enabled, then see if the actual and requested 
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
	string fn = "EnsureValidPendPrice[]";

	double 	servers_min_stop = MarketInfo(symbol, MODE_STOPLEVEL) * Point;
	double 	old_price, priceNow, hasSlippedBy;
	
	// Assume buy pendings relate to Ask, and sell pendings relate to Bid
	if (cmd % 2 == OP_BUY)
		priceNow = NormalizeDouble(MarketInfo(symbol, MODE_ASK), MarketInfo(symbol, MODE_DIGITS));
	else if (cmd % 2 == OP_SELL)
		priceNow = NormalizeDouble(MarketInfo(symbol, MODE_BID), MarketInfo(symbol, MODE_DIGITS));

	// If we are too close to put in a limit/stop order so go to market.
	if (MathAbs(priceNow - price) <= servers_min_stop)
	{
		if (gUseLimitToMarket)
		{
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
	
	// Sleep from 20-to-(2*gSleepAveTime) ms
	int ms = MathRound(2 * gSleepAveTime * rndm);
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
	gUseLimitToMarket = limit2market;
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
	gUseForTesting = use;
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
	gAddSpreadToComment = use;
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
	string fn = "GetOrderDetails[]";

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
				OrderReliablePrint(fn, "Could Not Select Ticket #" + lastTicket);
		}
	}
	
	// Get bid, ask, point & digits
	bid = NormalizeDouble(MarketInfo(symb, MODE_BID), MarketInfo(symb, MODE_DIGITS));
	ask = NormalizeDouble(MarketInfo(symb, MODE_ASK), MarketInfo(symb, MODE_DIGITS));
	point = MarketInfo(symb, MODE_POINT);
	if (point == 0.001  ||  point == 0.00001)
		point *= 10;
		
	digits = MarketInfo(symb, MODE_DIGITS);
	
	// If this is a forex pair (i.e. symbol length == 6), then digits should not be zero
	if (digits == 0  &&  StringLen(MySymbolVal2String(MySymbolConst2Val(Symbol()))) == 6)
	{
		OrderReliablePrint(fn, "error: MarketInfo(symbol (" + symb + "), MODE_DIGITS) == 0");
		return(false);
	}
	else if (exists)
	{
		tp = NormalizeDouble(tp, digits);
		sl = NormalizeDouble(sl, digits);
		bid = NormalizeDouble(bid, digits);
		ask = NormalizeDouble(ask, digits);
	}
	
	return(true);
}

//=============================================================================
// 20Jul16: Not sure what BS this is; all this ised to work, but not sure how.  
// DerksUtils includes OrderReliable, but not vice versa...  So copied these 
// functions from DerksUtils and changed the names.  Also, abive, where used, 
// it WAS: StringLen(MySymbolVal2String(Symbol())) == 6), which was wrong.
//=============================================================================
int MySymbolConst2Val(string symbol) 
{
	// Handle problem of trailing chars on mini accounts.
	string mySymbol = StringSubstr(symbol,0,6); 
	
	if (mySymbol == "AUDCAD") 	return(1);
	if (mySymbol == "AUDJPY") 	return(2);
	if (mySymbol == "AUDNZD") 	return(3);
	if (mySymbol == "AUDUSD") 	return(4);
	if (mySymbol == "CADJPY") 	return(5);
	if (mySymbol == "CHFJPY") 	return(6);
	if (mySymbol == "EURAUD") 	return(7);
	if (mySymbol == "EURCAD") 	return(8);
	if (mySymbol == "EURCHF") 	return(9);
	if (mySymbol == "EURGBP") 	return(10);
	if (mySymbol == "EURJPY") 	return(11);
	if (mySymbol == "EURUSD") 	return(12);
	if (mySymbol == "GBPCHF") 	return(13);
	if (mySymbol == "GBPJPY") 	return(14);
	if (mySymbol == "GBPUSD") 	return(15);
	if (mySymbol == "NZDJPY") 	return(16);
	if (mySymbol == "NZDUSD") 	return(17);
	if (mySymbol == "USDCAD") 	return(18);
	if (mySymbol == "USDCHF") 	return(19);
	if (mySymbol == "USDJPY")	return(20);
	
	// These symbols were added 26Sep10
	if (mySymbol == "AUDCHF") 	return(22);
	if (mySymbol == "AUDDKK") 	return(23);
	if (mySymbol == "AUDNOK") 	return(24);
	if (mySymbol == "AUDSEK") 	return(25);
	if (mySymbol == "CADCHF") 	return(26);
	if (mySymbol == "CHFNOK") 	return(27);
	if (mySymbol == "EURDKK")	return(28);
	if (mySymbol == "EURNZD") 	return(29);
	if (mySymbol == "EURPLN") 	return(30);
	if (mySymbol == "EURSEK")	return(31);
	if (mySymbol == "EURSGD") 	return(32);
	if (mySymbol == "EURZAR")	return(33);
	if (mySymbol == "GBPAUD") 	return(34);
	if (mySymbol == "GBPCAD") 	return(35);
	if (mySymbol == "GBPNOK") 	return(36);
	if (mySymbol == "GBPNZD") 	return(37);
	if (mySymbol == "GBPSGD") 	return(38);
	if (mySymbol == "NOKJPY") 	return(39);
	if (mySymbol == "NZDCAD") 	return(40);
	if (mySymbol == "NZDCHF") 	return(41);
	if (mySymbol == "NZDGBP") 	return(42);
	if (mySymbol == "SEKJPY") 	return(43);
	if (mySymbol == "USDAED")	return(44);
	if (mySymbol == "USDBHD")	return(45);
	if (mySymbol == "USDDKK")	return(46);
	if (mySymbol == "USDEGP")	return(47);
	if (mySymbol == "USDHKD")	return(48);
	if (mySymbol == "USDJOD")	return(49);
	if (mySymbol == "USDKWD")	return(50);
	if (mySymbol == "USDMXN")	return(51);
	if (mySymbol == "USDNOK")	return(52);
	if (mySymbol == "USDPLN")	return(53);
	if (mySymbol == "USDQAR")	return(54);
	if (mySymbol == "USDSAR")	return(55);
	if (mySymbol == "USDSEK")	return(56);
	if (mySymbol == "USDSGD")	return(57);
	if (mySymbol == "USDTHB")	return(58);
	if (mySymbol == "USDZAR")	return(59);
	if (mySymbol == "XAGUSD")	return(60);
	if (mySymbol == "XAUUSD")	return(61);
	
	// Originally, this was "other"; kept 
	// the same for backward compatability
	return(21);
}


string MySymbolVal2String(int val) 
{
	if (val == 1) 	return("AUDCAD");
	if (val == 2) 	return("AUDJPY");
	if (val == 3) 	return("AUDNZD");
	if (val == 4) 	return("AUDUSD");
	if (val == 5) 	return("CADJPY");
	if (val == 6) 	return("CHFJPY");
	if (val == 7) 	return("EURAUD");
	if (val == 8) 	return("EURCAD");
	if (val == 9) 	return("EURCHF");
	if (val == 10) 	return("EURGBP");
	if (val == 11) 	return("EURJPY");
	if (val == 12) 	return("EURUSD");
	if (val == 13) 	return("GBPCHF");
	if (val == 14) 	return("GBPJPY");
	if (val == 15) 	return("GBPUSD");
	if (val == 16) 	return("NZDJPY");
	if (val == 17) 	return("NZDUSD");
	if (val == 18) 	return("USDCAD");
	if (val == 19) 	return("USDCHF");
	if (val == 20)	return("USDJPY");
	
	// These symbols were added 26Sep10
	if (val == 22)	return("AUDCHF");
	if (val == 23)	return("AUDDKK");
	if (val == 24)	return("AUDNOK");
	if (val == 25)	return("AUDSEK");
	if (val == 26)	return("CADCHF");
	if (val == 27)	return("CHFNOK");
	if (val == 28)	return("EURDKK");
	if (val == 29)	return("EURNZD");
	if (val == 30)	return("EURPLN");
	if (val == 31)	return("EURSEK");
	if (val == 32)	return("EURSGD");
	if (val == 33)	return("EURZAR");
	if (val == 34)	return("GBPAUD");
	if (val == 35)	return("GBPCAD");
	if (val == 36)	return("GBPNOK");
	if (val == 37)	return("GBPNZD");
	if (val == 38)	return("GBPSGD");
	if (val == 39)	return("NOKJPY");
	if (val == 40)	return("NZDCAD");
	if (val == 41)	return("NZDCHF");
	if (val == 42)	return("NZDGBP");
	if (val == 43)	return("SEKJPY");
	if (val == 44)	return("USDAED");
	if (val == 45)	return("USDBHD");
	if (val == 46)	return("USDDKK");
	if (val == 47)	return("USDEGP");
	if (val == 48)	return("USDHKD");
	if (val == 49)	return("USDJOD");
	if (val == 50)	return("USDKWD");
	if (val == 51)	return("USDMXN");
	if (val == 52)	return("USDNOK");
	if (val == 53)	return("USDPLN");
	if (val == 54)	return("USDQAR");
	if (val == 55)	return("USDSAR");
	if (val == 56)	return("USDSEK");
	if (val == 57)	return("USDSGD");
	if (val == 58)	return("USDTHB");
	if (val == 59)	return("USDZAR");
	if (val == 60)	return("XAGUSD");
	if (val == 61)	return("XAUUSD");
	
	return("Unrecognized Pair");
}


