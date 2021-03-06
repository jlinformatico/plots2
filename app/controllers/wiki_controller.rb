require 'rss'

class WikiController < ApplicationController

  before_filter :require_user, :only => [:new, :create, :edit, :update, :delete]

  def show
    if params[:lang]
      @node = DrupalNode.find_by_slug(params[:lang]+"/"+params[:id])
    else
      @node = DrupalNode.find_by_slug(params[:id])
    end

    if !@node.nil? # it's a place page!
      @tags = @node.tags
      @tags += [DrupalTag.find_by_name(params[:id])] if DrupalTag.find_by_name(params[:id])
    else # it's a new wiki page!
      @title = "New wiki page"
      if current_user
        new
      else
        flash[:warning] = "That page does not yet exist. You must be logged in to create a new wiki page."
        redirect_to "/login"
      end
    end

    unless @title # the page exists
      if @node.status == 0
        flash[:warning] = "That page has been moderated as spam. Please contact web@publiclab.org if you believe there is a problem."
        redirect_to "/wiki"
      end
      @tagnames = @tags.collect(&:name)
      set_sidebar :tags, @tagnames, {:videos => true}
      @wikis = DrupalTag.find_pages(@node.slug,30) if @node.has_tag('chapter') || @node.has_tag('tabbed:wikis')

      @node.view
      @revision = @node.latest
      @title = @revision.title
    end
    @unpaginated = true
  end

  def edit
    if params[:lang]
      @node = DrupalNode.find_by_slug(params[:lang]+"/"+params[:id])
    else
      @node = DrupalNode.find_by_slug(params[:id])
    end
    # we could do this...
    #@node.locked = true
    #@node.save
    @title = "Editing '"+@node.title+"'"

    @tags = @node.tags
  end

  def new
    @tags = []
    if params[:id]
      flash.now[:notice] = "This page does not exist yet, but you can create it now:" 
      title = params[:id].gsub('-',' ')
      @related = DrupalNode.find(:all, :limit => 10, :order => "node.nid DESC", :conditions => ['type = "page" AND status = 1 AND (node.title LIKE ? OR node_revisions.body LIKE ?)', "%"+title+"%","%"+title+"%"], :include => :drupal_node_revision)
      tag = DrupalTag.find_by_name(params[:id]) # add page name as a tag, too
      @tags << tag if tag
      @related += DrupalTag.find_nodes_by_type(@tags.collect(&:name),'page',10)
    end
    render :template => 'wiki/edit'
  end

  def create
    if current_user.drupal_user.status == 1
      # we no longer allow custom urls, just titles which are parameterized automatically into urls
      #slug = params[:title].parameterize
      #slug = params[:id].parameterize if params[:id] != "" && !params[:id].nil?
      #slug = params[:url].parameterize if params[:url] != "" && !params[:url].nil?
      saved,@node,@revision = DrupalNode.new_wiki({
        :uid => current_user.uid,
        :title => params[:title],
        :body => params[:body]
      })
      if saved
        flash[:notice] = "Wiki page created."
        redirect_to @node.path
      else
        render :action => :edit
      end
    else
      flash.keep[:error] = "You have been banned. Please contact <a href='mailto:web@publiclab.org'>web@publiclab.org</a> if you believe this is in error."
      redirect_to "/logout"
    end
  end

  def update
    @node = DrupalNode.find(params[:id])
    @revision = @node.new_revision({
      :nid => @node.id,
      :uid => current_user.uid,
      :title => params[:title],
      :body => params[:body]
    })
    if @revision.valid?
      ActiveRecord::Base.transaction do
        @revision.save
        @node.vid = @revision.vid
        # update vid (version id) of main image
        if @node.drupal_main_image && params[:main_image].nil?
          i = @node.drupal_main_image
          i.vid = @revision.vid 
          i.save
        end
        # can't do this because it changes the URL:
        #@node.title = @revision.title
        # save main image
        if params[:main_image] && params[:main_image] != ""
          begin
            img = Image.find params[:main_image]
            unless img.nil?
              img.nid = @node.id
              img.save
            end
          rescue
          end
        end
        @node.save
      end
      flash[:notice] = "Edits saved."
      redirect_to @node.path
    else
      flash[:error] = "Your edit could not be saved."
      render :action => :edit
      #redirect_to "/wiki/edit/"+@node.slug
    end
  end

  def delete
    @node = DrupalNode.find(params[:id])
    if current_user && current_user.role == "admin"
      @node.transaction do
        @node.destroy
      end
      flash[:notice] = "Wiki page deleted."
      redirect_to "/dashboard"
    else
      flash[:error] = "Only admins can delete wiki pages."
      redirect_to @node.path
    end
  end

  def revert
    revision = DrupalNodeRevision.find params[:id]
    node = revision.parent
    if current_user && current_user.drupal_user.status == 1 && (current_user.role == "moderator" || current_user.role == "admin")
      new_rev = revision.dup
      new_rev.timestamp = DateTime.now.to_i
      if new_rev.save!
        flash[:notice] = "The wiki page was reverted."
      else
        flash[:error] = "There was a problem reverting."
      end
    else
      flash[:error] = "Only moderators and admins can delete wiki pages."
    end
    redirect_to node.path
  end

  # wiki pages which have a root URL, like http://publiclab.org/about
  def root
    @node = DrupalNode.find_root_by_slug(params[:id])
    @revision = @node.latest
    @title = @revision.title
    @tags = @node.tags
    @tagnames = @tags.collect(&:name)
    render :template => "wiki/show"
  end

  def revisions
    @node = DrupalNode.find_by_slug(params[:id])
    @title = "Revisions for '"+@node.title+"'"
    @tags = @node.tags
  end

  def revision
    @node = DrupalNode.find_by_slug(params[:id])
    @tags = @node.tags
    @revision = DrupalNodeRevision.find_by_nid_and_vid(@node.id, params[:vid])
    if @revision.nil?
      # revision not found, forward to revision list
      flash[:error] = "invalid revision " + params[:vid]
      redirect_to action: 'revisions'
    else
      @title = "Revision for '"+@revision.title+"'"
      render :template => "wiki/show"
    end
  end

  def index
    @title = "Wiki index"
    @wikis = DrupalNode.find_all_by_type('page',10,:limit => 50, :joins => 'JOIN node_revisions ON node_revisions.nid = node.nid', :order => "node_revisions.timestamp DESC", :conditions => ["status = 1 AND node.nid != 259 AND (type = 'page' OR type = 'tool' OR type = 'place')"]).uniq
  end

  def popular
    @title = "Popular wiki pages"
    @wikis = DrupalNode.find(:all, :limit => 40,:order => "node_counter.totalcount DESC", :conditions => ["status = 1 AND node.nid != 259 AND (type = 'page' OR type = 'tool' OR type = 'place')"], :include => :drupal_node_counter)
    render :template => "wiki/index"
  end

  def liked
    @title = "Well-liked wiki pages"
    @wikis = DrupalNode.find(:all, :limit => 40,:order => "node.cached_likes DESC", :conditions => ["status = 1 AND nid != 259 AND (type = 'page' OR type = 'tool' OR type = 'place') AND cached_likes > 0"])
    render :template => "wiki/index"
  end

end
