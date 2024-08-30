/********************************************************************************/
/*   SAS Code for Pre-processing Time Series Data for Model Comparison Job      */
/*                                                                              */
/*   This script creates a CAS session and assigns SAS librefs for existing     */
/*   caslibs. It then pre-processes your initial time series dataset to ensure  */
/*   it has the proper structure required for the ModelComparison job.          */
/*                                                                              */
/*   NOTE: Modify the first 5 lines to match your dataset and variable names.   */
/********************************************************************************/
%let originaltab = sashelp.pricedata;   /* The original SAS dataset to be processed */
%let castab = casuser.pricedata;        /* The CAS table where the processed data will be stored */
%let target = sale;                     /* The target variable to be aggregated and analyzed */
%let date = date;                       /* The date variable that represents the time dimension */
%let byvar = regionname;                /* The categorical variable used for grouping the data */

/* No modification needed beyond this point */
%let caslib = %scan("&castab", 1, ".");
%let casdata = %scan("&castab", 2, ".");

cas mySession;
caslib _all_ assign;

proc casutil;
	droptable casdata="&casdata" incaslib="&caslib" quiet;
quit;

data &castab._tmp;
    set &originaltab;
run;

proc cas;
    casTbl = {
        caslib="&caslib", 
        name="&casdata"
    };

    source long_table;
        create table &castab as
        select &byvar, &date, sum(&target) as &target
        from &castab._tmp
        group by &byvar, &date;
    endsource;

    fedSQL.execDirect / query=long_table;

    dataShaping.wideToLong /
        table=casTbl,
        id={"&byvar", "&date"},
        casOut={caslib="&caslib",
                name="&casdata",
                replace=true};
    
    table.alterTable /
        name = casTbl['name'],
        caslib = casTbl['caslib'],
        columnOrder = {"&byvar", "&date", 'variableName', 'variableValue'},
        columns = {
            {name = '_C0_', drop = True},
            {name = '_Variable_', rename = 'variableName', label = 'Variable name', format=''},
            {name = '_Value_', rename = 'variableValue', label = 'Variable value', format=''}
        };
quit;

data &castab(promote=yes);
    retain &byvar &date variableName variableValue;
    length variableName $23;
    set &castab;
run;

proc print data=&castab noobs;
quit;

cas mySession terminate;