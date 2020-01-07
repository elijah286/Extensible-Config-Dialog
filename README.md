# Extensible-Config-Dialog
LabVIEW Reference Architecture for Configuration Dialogs

Overview:
This provides a framework for configuraiton dialogs that uses a plugin model built on actor framework. It simplifies the task of reading/writing configuration to disk and taking care of formatting for arbitrary data

Installation:
1) Run the included VIPC file to automatically download and install required dependncies, which includes:
- oglib_array
- oglib_error
- oglib_string
- oglib_lvdata
- oglib_variantconfig
- oglib_appcontrol
- oglib_file

2) Open and run TESTING ONLY.vi to ensure everything is setup and loaded correctly
- If it works correctly, a blank configuration dialog should appear
- If running this vi results in the error "An error will be thrown if the configuration dialog attempts to return any message to the calling actor other than the 'Handle Last Ack,' the path is invalid.
- Change the path to a valid directory

Running example with plugins
1) Navigate to /Basic Configuration Dialog and open the included project 'Config Dialog Example'
2) Open 'Launch Example Dialog.vi'
2) Modify the path to point to the included 'ConfigFile.ini' file in the same directory
3) Run the VI
4) Change settings and confirm that the ini file is modified
