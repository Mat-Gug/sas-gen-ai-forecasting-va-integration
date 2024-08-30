# AI powered Time-Series Forecasting in SAS® Visual Analytics: Gen AI Foundation Models in action
Traditionally, time series forecasting has relied heavily on statistical and machine learning models. However, recent advancements in deep learning, specifically the emergence of **foundation models (FMs)**, are starting to revolutionize this field.

This repository includes files that integrate Foundation Forecasting Models into SAS® Visual Analytics (VA), allowing users to train and compare these advanced models alongside traditional forecasting techniques directly within the dashboard.

## ModelComparison Folder Contents
The `ModelComparison` folder includes the following files:

* `preprocessing.sas`: This SAS script performs data pre-processing to prepare your dataset for use within the dashboard.
* `ModelComparison.html`: The HTML form associated with the SAS Viya Job, which is displayed in the Data-Driven Content (DDC) object of the dashboard.
* `ModelComparison.sas`: The SAS Viya Job code that runs when a model is selected for training within the DDC object. Currently, this code utilizes [Amazon Science's Chronos model](https://github.com/amazon-science/chronos-forecasting) as the Foundation Forecasting Model.
* `ModelComparison.xml`: An XML file that allows users to replicate the dashboard setup, maintaining the same structure and settings as in the original configuration.

