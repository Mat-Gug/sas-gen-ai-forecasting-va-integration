*==================================================================;
* Initialization;
*==================================================================;

* This allows for unconventional column names (e.g.: spaces, etc.);
options VALIDVARNAME=any;

* _appout contains the application's return code in json format: {success:<true/false>, message:<msg>};
filename _appout filesrvc parenturi="&SYS_JES_JOB_URI" name='_appout.json';

%macro sendApplicationMsg(msg, success);
  %put &=msg;
  proc json out=_appout nosastags nopretty nokeys;
    write open object;
    write values "success" &SUCCESS;
    write values "message" "&MSG";
    write close;
  run;
  %if &SUCCESS eq false %then %do;
  	cas mySession terminate;
  	%abort cancel;
  %end;
%mend sendApplicationMsg;

* Connect to CAS;
cas mySession;

%macro checkParams;
	%if (not %symexist(CASTAB)) %then %sendApplicationMsg(Missing parameter CASTAB, false);
    %if (not %sysfunc(exist(&CASTAB))) %then %sendApplicationMsg(Table &CASTAB does not exist, false);
    %if (not %symexist(model)) %then %sendApplicationMsg(The MODEL parameter has not been sent to the job. Include it in the POST request., false);
	%if (not %symexist(byvariable)) %then %sendApplicationMsg(Missing parameter BYVARIABLE, false);
	%if (not %symexist(target)) %then %sendApplicationMsg(Missing parameter TARGET, false);
	%if (not %symexist(date)) %then %sendApplicationMsg(Missing parameter DATE, false);
    %if (not %symexist(date_interval)) %then %sendApplicationMsg(Missing parameter DATE_INTERVAL, false);
	%if (not %symexist(byvar)) %then %sendApplicationMsg(Missing parameter BYVAR, false);
%mend checkParams;
%checkParams;

%let caslib = %scan("&castab", 1, ".");
%let casdata = %scan("&castab", 2, ".");

* Assign the &CASLIB library;
libname &caslib CAS caslib="&caslib";

*==================================================================;
* Data Preparation;
*==================================================================;

%IF &byvariable= %then %do;
	proc contents data=&castab noprint out=work.tab_info;
	run;
	
	proc sql noprint;
	    select length into :length_value 
	    from work.tab_info
	    where upper(name)=upper(%tslit(&byvar));
	quit;

	proc cas;
	    source aggregate_table;
	        create table &castab._aggregate {options replace=true} as
	        select 
	            CAST('.' AS CHAR(&length_value)) as &byvar,
	            &date,
	            sum(variableValue) as variableValue
	        from &castab
	        where upper(variableName) = upper(%tslit(&target))
	        group by &date;
	    endsource;
	
	    fedSQL.execDirect /
	        showStages=true
	        query=aggregate_table;
	quit;
%end;

%else %do;
    proc cas;
        source aggregate_table;
            create table &castab._aggregate {options replace=true} as
            select 
                &byvar,
                &date,
                sum(variableValue) as variableValue
            from &castab
            where upper(variableName) = upper(%tslit(&target)) and &byvar = %tslit(&byvariable)
            group by &byvar, &date;
        endsource;

        fedSQL.execDirect /
        	showStages=true
        	query=aggregate_table;
    quit;
%end;

*==================================================================;
* Model-Specific Forecasting;
*==================================================================;

%IF &model=ma %then %do;
    proc tsmodel data = &castab._aggregate
	             out = &caslib..timeSeries
	             outarray = &caslib..newTimeSeries
	             lead = 12;
            register tsm;
            by &byvar;
            id &date interval=&date_interval;
            var variableValue /accumulate=sum;
            outarrays forecastedMA;

        submit;
            *moving average forecasts;
            declare object mavgSpec(ARIMASPEC);
            declare object mavgTsm(TSM);

            *specify moving average model parameters;
            rc = mavgSpec.open();
            
            *setup spec for moving average of window 12;
            window = int(12);
            beta = 1/window;

            array AROrder[1]/nosymbols;
            call dynamic_array(AROrder, window);
            array ARCoeff[1]/nosymbols;
            call dynamic_array(ARCoeff, window);

            * AROrder specifies AR polynomial lags that our model needs to contain;
            * ARCoeff specifies the AR polynomial coefficients for each lag;
            do i = 1 to window;
                AROrder[i] = i;
                ARCoeff[i] = beta;
            end;

            rc = mavgSpec.addARPoly(AROrder, window, 0, ARCoeff);

            *no estimate, no intercept;
            rc = mavgSpec.setOption('noint', 1, 'noest', 1, 'nostable', 1);
            rc = mavgSpec.close();

            *setup the TSM object;
            rc = mavgTsm.initialize(mavgSpec);
            rc = mavgTsm.setY(variableValue);
            rc = mavgTsm.setOption('lead', _LEAD_);
            rc = mavgTsm.run();

            *collect the forecast;
            rc = mavgTsm.getForecast('predict', forecastedMA);
        endsubmit;
    run;
%END;




%IF &model=snaive %then %do;
    proc tsmodel data = &castab._aggregate
                out = &caslib..timeSeries
                outarray = &caslib..newTimeSeries
                lead=12;
        by &byvar;
        id &date interval=&date_interval;
        var variableValue /accumulate=sum;
        outarrays forecastedSeasonalNaive;
    
        submit;
            *create lag of dependent variable;
            %let T = _LENGTH_-_LEAD_;
            %let m = _SEASONALITY_;
            do i = 1 to &T+_LEAD_;
                if i < &m+1 then forecastedSeasonalNaive[i] = .;
                else if i > &T then forecastedSeasonalNaive[i] = variableValue[&T+(i-&T)-&m*(FLOOR((i-&T-1)/&m)+1)];
                else forecastedSeasonalNaive[i] = variableValue[i-&m];
            end;
        endsubmit;
    run;
%END;





%IF &model=esm %then %do;
    proc tsmodel data=&castab._aggregate
        outarray=&caslib..newTimeSeries
        lead=12;
        by &byvar;
        id &date interval=&date_interval;
        var variableValue /accumulate=sum;
        outarray forecastedEsm;

        *use TSM package;
        register tsm;

        submit;
            * declare TSM objects;
            declare object spec(esmspec);
            declare object esm(tsm);

            * specify ESM model parameters;
            * see https://go.documentation.sas.com/doc/en/pgmsascdc/v_015/casecon/casecon_tsm_sect057.htm for more details;
            rc = spec.Open();
            rc = spec.SetTransform('none');
            rc = spec.SetOption('method', 'best',
                                'criterion', 'mase');
            * Close() prepares the ESM model to be used in a TSM object or to be imported to a TSMSPEC object
            * for printing or for storage in a model repository catalog;
            rc = spec.Close();

            *set time series, run ESM model;
            rc = esm.Initialize(spec);
            rc = esm.SetY(variableValue);
            rc = esm.Run();

            *collect the forecasts into object called forecastedEsm;
            rc = esm.GetForecast('predict', forecastedEsm);
        endsubmit;
    run;
%END;





%IF &model=chronos %then %do;
    proc tsmodel data=&castab._aggregate
        outarray=&caslib..newTimeSeries
        outobj=( 
            pylog=&caslib..chronos_pylog
        )
        lead=12;
        by &byvar;
        id &date interval=&date_interval;
        var variableValue /accumulate=sum;

        outarray forecastedChronos;
        require extlang;

    submit;

        * endpoint of the chronos model;
        CHRONOS_ENDPOINT = "https://<your.host.name>/<YOUR_CHRONOS_ENDPOINT>";
        * increases performance and runtime;
        NUM_SAMPLES = 100;
        * token generation parameters;
        TEMPERATURE = 1;
        TOP_K = 50;
        TOP_P = 1;

    declare object py(PYTHON3);
    	rc = py.Initialize();

        rc = py.AddVariable(variableValue,'ALIAS','TARGET') ;
        rc = py.AddVariable(&date, 'ALIAS', 'ds');
        rc = py.AddVariable(CHRONOS_ENDPOINT);
        rc = py.AddVariable(_LEAD_);
        rc = py.AddVariable(_SEASONALITY_);
        rc = py.AddVariable(NUM_SAMPLES);
        rc = py.AddVariable(TEMPERATURE);
        rc = py.AddVariable(TOP_K);
        rc = py.AddVariable(TOP_P);
        rc = py.AddVariable(forecastedChronos,"READONLY","NO","ARRAYRESIZE","YES","ALIAS",'PREDICT');

        * Packages needed for processing the call;
        rc = py.pushCodeLine("import json");
        rc = py.pushCodeLine("import math");
        rc = py.pushCodeLine("import requests as req");
        rc = py.pushCodeLine("import numpy as np");
        rc = py.pushCodeLine("import pandas as pd");

        * Import the variables set outside of the python code;
        rc = py.pushCodeLine("url = CHRONOS_ENDPOINT");
        rc = py.pushCodeLine("prediction_length = int(_LEAD_)");
        rc = py.pushCodeLine("season_length = int(_SEASONALITY_)");
        rc = py.pushCodeLine("num_samples = int(NUM_SAMPLES)");
        rc = py.pushCodeLine("temperature = float(TEMPERATURE)");
        rc = py.pushCodeLine("top_k = int(TOP_K)");
        rc = py.pushCodeLine("top_p = float(TOP_P)");

        /********************************************************************/
        /*         API Call to run a prediction for the time window         */
        /*            defined by _LEAD_ (=prediction_length)                */
        /********************************************************************/

        * Set the options for the model API call;
        rc = py.pushCodeLine("payload = json.dumps({");
        rc = py.pushCodeLine("'prediction_length': prediction_length,");
        rc = py.pushCodeLine("'num_samples': num_samples,");
        rc = py.pushCodeLine("'temperature': temperature,");
        rc = py.pushCodeLine("'top_k': top_k,");
        rc = py.pushCodeLine("'top_p': top_p,");
        
		* Here we give to Chronos all the past values;
        rc = py.pushCodeLine("'data': TARGET.tolist()");
        rc = py.pushCodeLine("})");
        rc = py.pushCodeLine("headers = {'Content-Type': 'application/json'}");
        
        /* The call will return a string with 3 (Median Forecast and limits of the 80% prediction interval) */
        /* by X values, where X is the prediction length. The values are separated by commas.               */
        rc = py.pushCodeLine("resp = req.post(url, headers=headers, data=payload, verify=False)");

        rc = py.pushCodeLine("forecast = resp.text.splitlines()");
        rc = py.pushCodeLine("forecast_header = forecast[0].split(',')");
        rc = py.pushCodeLine("forecast_values = np.genfromtxt(forecast, delimiter=',', skip_header=1)");

        /****************************************************************************/
        /* Generate an empty numpy ndarray so that the predicted values             */
        /* are appended at the right index. Initialize the prediction variable      */
        /* by putting the first TARGET.shape[0]-prediction_length variables to nan. */
		/* NOTE: the TARGET variable has length equal to:                           */
		/*         number of target variable's values + prediction_length           */
        /****************************************************************************/
        rc = py.pushCodeLine("prediction = np.empty(TARGET.shape[0] - prediction_length)");
        rc = py.pushCodeLine("prediction[:] = np.nan");

		* Add the forecasted prediction_length values to the prediction array;
		rc = py.pushCodeLine("prediction = np.concatenate((prediction, forecast_values[:, forecast_header.index('median')]))");

        rc = py.pushCodeLine("PREDICT = prediction");

        rc = py.Run();
		
        declare object pylog(OUTEXTLOG);
        rc = pylog.Collect(py, 'EXECUTION');
		
        endsubmit;
    run;
%END;

*==================================================================;
* Post-Processing;
*==================================================================;

data _null_;
    set &castab(obs=1);
    format_value = vformat(&date);
    call symputx('format_value', format_value);
    stop;
run;

proc cas;
    casTbl = {caslib="&caslib", 
              name='newTimeSeries'};

    table.alterTable /
        name = casTbl['name'],
        caslib = casTbl['caslib'],
        drop = {'_STATUS_', '_SEASON_', '_CYCLE_', 'variableValue'};
    
    dataShaping.wideToLong /
        table=casTbl,
        id={"&byvar", "&date"},
        casOut={caslib=casTbl['caslib'], 
                name=casTbl['name'],
                replace=True};
    
     table.alterTable /
        name = casTbl['name'],
        caslib = casTbl['caslib'],
        columns = {
            {name = '_C0_', drop = True},
            {name = '_Variable_', rename = 'variableName', label = 'Variable name', format = ''},
            {name = '_Value_', rename = 'variableValue', label = 'Variable value', format=''},
            {name = "&date", format = "&format_value"}
        };
    run;
quit;

data &caslib..newTimeSeries;
    length variableName $23;
    set &caslib..newTimeSeries;
run;

data &castab(append=yes);
    set &caslib..newTimeSeries;
run;

*==================================================================;
* Termination;
*==================================================================;

cas mySession terminate;

* The return code is sent back to the calling client (Data-Driven Content object) in JSON format;
%sendApplicationMsg(success, true);