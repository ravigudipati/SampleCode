# To write multiple records at a time
    def batch_save options = {}
      result = ''
      rec_str = ''
      req_fields = ['label', 'value']

      # Make sure the data exists & validate required fields
      if options.nil?
        result = 'No data is available to write into tsdb.'
        return result
      end

      # Check for required fields for all records
      options.each do|rec,v|
        req_fields.each do|f|
          if v[f.to_sym].nil?
            result = "#{f} is required to write into tsdb."
            return result
          end
        end
      end

      # Format the string for Opentsdb
      options.each do|rec,v|
        data_str = ''
        v[:data].each{|key,val| data_str += "#{key}=#{val} "}
        rec = ['put',v[:label],v[:currenttime],v[:value],data_str.rstrip].join(' ')
        rec_str = rec_str + '"' + rec + '"$\'\\n\''
      end

      rec_str = rec_str.slice(0..-6)

      # Write into the db
      # This command takes more time to finish for large dataset
      ret = system("echo #{rec_str} | nc -w 30 #{@host} #{@port}")

      #stdin, stdout, stderr, wait_thr = Open3.popen3("echo #{rec_str} | nc -w 30 #{@host} #{@port}")
      

      # Command failed to run
      unless ret || ret.nil?
        result = "Command failed to insert #{rec_str} into TSDB." 
        return result
      end

      ' '
    end

    private

    # Returns:
    # Response in the specified format for the given http request
    def get_response url, format
      begin
        response = Net::HTTP.get_response(URI.parse(url))
        if format.to_sym == :json
          res = JSON.parse response.body
        else
          res = response.body
        end
      rescue Exception => e
        res = "ERROR: There is a problem while fetching data, please check whether OpenTSDB is running or not."
      end
      res
    end

    # Parses a query param hash into a query string as expected by OpenTSDB
    # *Params:*
    # * params the parameters to parse into a query string
    # * requirements: any required parameters
    # *Returns:*
    # A query string
    # Raises:
    # ArgumentError if a required parameter is missing
    def query_params params = {}, requirements = []
      query = []

      requirements.each do |req|
        unless params.keys.include?(req.to_sym) || params.keys.include?(req.to_s)
          raise ArgumentError.new("#{req} is a required parameter.")
        end
      end

      params.each_pair do |k,v|
        if v.respond_to? :each
          v.each do |subv|
            query << "#{k}=#{subv}"
          end
        else
          v = v.strftime('%Y/%m/%d-%H:%M:%S') if v.respond_to? :strftime
          query << "#{k}=#{v}"
        end
      end
      query.join '&'
    end
